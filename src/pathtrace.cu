#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <chrono>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/sort.h>
#include <thrust\device_vector.h>
#include <stream_compaction/efficient.h>
#include <thrust/partition.h>
#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"
#include "device_launch_parameters.h"
#include "utilities.h"
#include "tiny_gltf.h"

#define ERRORCHECK 1
#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

/*
 * Kernel that writes the image to the OpenGL PBO directly.
 */
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Triangle * dev_meshes = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static ShadeableIntersection * dev_cached_intersections = NULL;
static int* dev_leftover_indices = NULL;

void pathtraceInit(Scene *scene) {
	hst_scene = scene;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_meshes, scene->mesh.num_triangles * sizeof(Triangle));
	cudaMemcpy(dev_meshes, scene->mesh.triangles.data(), scene->mesh.num_triangles * sizeof(Triangle), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_cached_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMalloc(&dev_leftover_indices, pixelcount * sizeof(int));

	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms); 
	cudaFree(dev_meshes);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_cached_intersections);
	cudaFree(dev_leftover_indices);
	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments, int* dev_leftover_indices)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);

		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, segment.remainingBounces);
		float jittered_x = x;
		float jittered_y = y;
		#if ANTI_ALIASING
				thrust::uniform_real_distribution<float> u01(-0.5f, 0.5f);
				jittered_x += u01(rng);
				jittered_y += u01(rng);
		#endif
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)jittered_x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)jittered_y - (float)cam.resolution.y * 0.5f)
		);

		segment.pixelIndex = index;
		dev_leftover_indices[index] = index;
		segment.remainingBounces = traceDepth;
	}
}

/*
 * Handles ray intersections with cube and sphere
 */
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, Triangle * triangles
	, int num_triangles
	, int geoms_size
	, ShadeableIntersection * intersections
	, int iter
	, int* dev_leftover_indices
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		int path_index = dev_leftover_indices[idx];
		PathSegment pathSegment = pathSegments[path_index];
		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				#if MOTION_BLUR
					glm::mat4 start = geom.initial_transform;
					glm::mat4 off(1.f); 
					off[2] += glm::vec4(0.f, MOTION_BLUR_OFFSET, 0.f, 0.f);
					geom.transform = start + off * (iter / 300.f);
					geom.inverseTransform = glm::inverse(geom.transform);
					geom.invTranspose = glm::transpose(glm::inverse(geom.transform));
				#endif
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if(geom.type == MESH){
				t = meshIntersectionTest(triangles, num_triangles, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (t > 0.0f && t_min > t)
			{
				t_min = t;
				hit_geom_index = i;
				intersect_point = tmp_intersect;
				normal = tmp_normal;
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].intersection = tmp_intersect;
		}
	}
}

/*
 * Real Shader 
 */
__global__ void shadeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
	, int depth
	, int* dev_leftover_indices
)
{
	int id = blockIdx.x * blockDim.x + threadIdx.x;
	if (id < num_paths && pathSegments[dev_leftover_indices[id]].remainingBounces > 0)
		{
		int idx = dev_leftover_indices[id];
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
			// Set up the RNG
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, depth);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray and terminate that path
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
				pathSegments[idx].remainingBounces = 0;
			}else {
				scatterRay(pathSegments[idx], intersection.intersection, intersection.surfaceNormal, material, rng);
				pathSegments[idx].remainingBounces -= 1;
			}
		} else {
			// If there was no intersection, color the ray black.
			pathSegments[idx].color = glm::vec3(0.0f);
			pathSegments[idx].remainingBounces = 0;
		}
		// Need to remove the dead rays from next iteration
		#if COMPACT_RAYS
			if (pathSegments[idx].remainingBounces <= 0)
				dev_leftover_indices[id] = -1;
		#endif
	}
}

/*
 *  Add the current iteration's output to the overall image
 */
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

/*
 * Was using it with thrust::removeif, using my own stream compaction now
 */
struct is_complete
{
	__host__ __device__
		bool operator()(const int idx)
	{
		return (idx == -1);
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
	auto start = std::chrono::high_resolution_clock::now();
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera &cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths, dev_leftover_indices);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	bool iterationComplete = false;
	while (!iterationComplete) {
		ShadeableIntersection* dev_cur_intersections = dev_intersections;
		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		#if CACHE_FIRST_BOUNCE && !ANTI_ALIASING
				if(depth == 0 && iter != 1) {
					dev_cur_intersections = dev_cached_intersections;
				}else {
					computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
						depth
						, num_paths
						, dev_paths
						, dev_geoms
						, dev_meshes
						, hst_scene->mesh.num_triangles
						, hst_scene->geoms.size()
						, dev_intersections
						, iter
						, dev_leftover_indices
						);
					if(depth == 0 && iter == 1){
						cudaMemcpy(dev_cached_intersections, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
					}
				}
		#else
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
					depth
					, num_paths
					, dev_paths
					, dev_geoms
					, dev_meshes
					, hst_scene->mesh.num_triangles
					, hst_scene->geoms.size()
					, dev_intersections
					, iter
					, dev_leftover_indices
					);
		#endif
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();
		depth++;

		#if MATERIAL_BASED_SORT 
			thrust::device_ptr<ShadeableIntersection> thrust_dev_intersections(dev_intersections);
			thrust::device_ptr<PathSegment> thrust_dev_paths(dev_paths);
			thrust::sort_by_key(thrust::device, thrust_dev_intersections, thrust_dev_intersections + num_paths, thrust_dev_paths);
		#endif
		shadeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_cur_intersections,
			dev_paths,
			dev_materials,
			depth,
			dev_leftover_indices
		);
		#if COMPACT_RAYS
			num_paths = StreamCompaction::Shared::compactCUDA(num_paths, dev_leftover_indices);
		#endif
		if((depth == traceDepth) || num_paths == 0)
			iterationComplete = true;
	}
	num_paths = pixelcount;

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather << <numBlocksPixels, blockSize1d >> > (pixelcount, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
	auto finish = std::chrono::high_resolution_clock::now();
	std::chrono::duration<double> elapsed = finish - start;
	if (iter <= 10)
		std::cout << elapsed.count() << "\n";
}
