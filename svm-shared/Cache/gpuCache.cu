//
// Created by shijiashuai on 2016/12/16.
//

#include <cublas_v2.h>
#include "gpuCache.h"
#include "../constant.h"
#include "subHessianCalculator.h"


void GpuCache::enable(int i, int j, const SvmProblem &subProblem) {
    if (binary){
        checkCudaErrors(cudaMallocPitch((void**)&devSharedCache[0],
                                        &sizeOfEachRowInCache[0],
                                        problem.getNumOfSamples() * sizeof(float_point),
                                        cacheSize[0]));
        numOfElementEachRowInCache[0] = sizeOfEachRowInCache[0] / sizeof(float_point);
        if(canPreComputeSharedCache) {
            printf("cache is large enough, pre-computing\n");
            float_point *devC;
            checkCudaErrors(cudaMalloc((void**)&devC, sizeof(float_point) * problem.getNumOfSamples() * problem.getNumOfSamples()));
            SubHessianCalculater::preComputeCache4BinaryProblem(devC,problem,param);
            checkCudaErrors(cudaMemcpy2D(devSharedCache[0],
                                         sizeOfEachRowInCache[0],
                                         devC,
                                         sizeof(float_point) * problem.getNumOfSamples(),
                                         sizeof(float_point) * problem.getNumOfSamples(),
                                         cacheSize[0],
                                         cudaMemcpyDeviceToDevice));
            checkCudaErrors(cudaFree(devC));
        }
    } else {
        //enable shared cache for class i and j
        this->subProblem = &subProblem;
        canPreComputeUniqueCache = true;

        //allocate memory for two shared caches
        checkCudaErrors(cudaMallocPitch((void **) &(devSharedCache[i]),
                                        &sizeOfEachRowInCache[i], problem.count[i] * sizeof(float_point),
                                        cacheSize[i]));
        checkCudaErrors(cudaMallocPitch((void **) &(devSharedCache[j]),
                                        &sizeOfEachRowInCache[j], problem.count[j] * sizeof(float_point),
                                        cacheSize[j]));
        numOfElementEachRowInCache[i] = sizeOfEachRowInCache[i] / sizeof(float_point);
        numOfElementEachRowInCache[j] = sizeOfEachRowInCache[j] / sizeof(float_point);

        //allocate memory for the first unique cache
        int uniqueCacheRowLength = problem.count[j];
        int uniqueCacheSize = min(CACHE_SIZE * 1024 * 1024 / 6 / uniqueCacheRowLength, cacheSize[i]);
        if (cacheSize[i] < problem.count[i]) canPreComputeUniqueCache = false;
        printf("unique cache 0 row length %d, size %d\n", uniqueCacheRowLength, uniqueCacheSize);

        checkCudaErrors(cudaMallocPitch((void **) &devUniqueCache[0],
                                        &sizeOfEachRowInUniqueCache[0],
                                        uniqueCacheRowLength * sizeof(float_point),
                                        uniqueCacheSize));
        numOfElementEachRowInUniqueCache[0] = sizeOfEachRowInUniqueCache[0] / sizeof(float_point);
        uniqueCacheStrategy[0] = new CLATCache(problem.count[i]);
        uniqueCacheStrategy[0]->SetCacheSize(uniqueCacheSize);
        uniqueCacheStrategy[0]->InitializeCache(uniqueCacheSize, problem.count[i]);
        //allocate memory for the second unique cache
        uniqueCacheRowLength = problem.count[i];
        uniqueCacheSize = min(CACHE_SIZE * 1024 * 1024 / 6 / uniqueCacheRowLength, cacheSize[j]);
        printf("unique cache 1 row length %d, size %d\n", uniqueCacheRowLength, uniqueCacheSize);
        if (cacheSize[j] < problem.count[j]) canPreComputeUniqueCache = false;
        checkCudaErrors(cudaMallocPitch((void **) &devUniqueCache[1],
                                        &sizeOfEachRowInUniqueCache[1],
                                        uniqueCacheRowLength * sizeof(float_point),
                                        uniqueCacheSize));
        numOfElementEachRowInUniqueCache[1] = sizeOfEachRowInUniqueCache[1] / sizeof(float_point);
        uniqueCacheStrategy[1] = new CLATCache(problem.count[j]);
        uniqueCacheStrategy[1]->SetCacheSize(uniqueCacheSize);
        uniqueCacheStrategy[1]->InitializeCache(uniqueCacheSize, problem.count[j]);

        //fill the two shared caches
        checkCudaErrors(cudaMemcpy2D(
                devSharedCache[i], sizeOfEachRowInCache[i],
                hostSharedCache[i], problem.count[i] * sizeof(float_point),
                problem.count[i] * sizeof(float_point), cacheSize[i], cudaMemcpyHostToDevice));
        checkCudaErrors(cudaMemcpy2D(
                devSharedCache[j], sizeOfEachRowInCache[j],
                hostSharedCache[j], problem.count[j] * sizeof(float_point),
                problem.count[j] * sizeof(float_point), cacheSize[j], cudaMemcpyHostToDevice));

        //fill the two unique caches, or decide to compute them on-the-fly
        if (canPreComputeUniqueCache) {
            SubHessianCalculater::preComputeUniqueCache(i, j, subProblem,
                                                        devUniqueCache, sizeOfEachRowInUniqueCache,
                                                        numOfElementEachRowInUniqueCache, param);
        } else {
            if (!preComputeInHost) {
                printf("compute unique kernels on-the-fly\n");
                hessianCalculator = new DeviceHessianOnFly(subProblem, param.gamma);
            } else
                printf("use pre-compute hessian matrix in host\n");
        }
    }
}

void GpuCache::disable(int i, int j) {
    if (binary){
        checkCudaErrors(cudaFree(devSharedCache[0]));
    } else {
        if (NULL != hessianCalculator)
            delete hessianCalculator;
        delete uniqueCacheStrategy[0];
        delete uniqueCacheStrategy[1];
        //copy the two precomputed shared caches back to host
        checkCudaErrors(cudaMemcpy2D(
                hostSharedCache[i], problem.count[i] * sizeof(float_point),
                devSharedCache[i], sizeOfEachRowInCache[i],
                problem.count[i] * sizeof(float_point), cacheSize[i], cudaMemcpyDeviceToHost));
        checkCudaErrors(cudaMemcpy2D(
                hostSharedCache[j], problem.count[j] * sizeof(float_point),
                devSharedCache[j], sizeOfEachRowInCache[j],
                problem.count[j] * sizeof(float_point), cacheSize[j], cudaMemcpyDeviceToHost));
        checkCudaErrors(cudaFree(devSharedCache[i]));
        checkCudaErrors(cudaFree(devSharedCache[j]));
        checkCudaErrors(cudaFree(devUniqueCache[0]));
        checkCudaErrors(cudaFree(devUniqueCache[1]));
    }
}

GpuCache::GpuCache(const SvmProblem &problem, const SVMParam &param) :
        problem(problem), param(param),
        numOfElementEachRowInCache(problem.getNumOfClasses()),
        devSharedCache(problem.getNumOfClasses(), NULL),
        sizeOfEachRowInCache(problem.getNumOfClasses()),
        devUniqueCache(2),
        uniqueCacheStrategy(2),
        numOfElementEachRowInUniqueCache(2),
        sizeOfEachRowInUniqueCache(2),
        canPreComputeSharedCache(true),
        preComputeInHost(false),
        hessianCalculator(NULL) {
    if (problem.getNumOfClasses() == 2){
        binary = true;
        printf("binary problem, use only one cache\n");
        int rowLength = problem.getNumOfSamples();
        sharedCacheStrategy.push_back(new CLATCache(rowLength));
        cacheSize.push_back(min(CACHE_SIZE * 1024 * 256 / rowLength, rowLength));
        if (cacheSize[0] < problem.getNumOfFeatures()) canPreComputeSharedCache = false;
        sharedCacheStrategy[0]->SetCacheSize(cacheSize[0]);
        sharedCacheStrategy[0]->InitializeCache(cacheSize[0], rowLength);
    } else {
//    checkCudaErrors(cudaMallocHost((void **) &hostHessianMatrix,
//                                   sizeof(float_point) * problem.getNumOfSamples() * problem.getNumOfSamples()));
//    SubHessianCalculater::preComputeAndStoreInHost(hostHessianMatrix, problem, preComputeInHost, param);
        for (int i = 0; i < problem.getNumOfClasses(); ++i) {
            int rowLength = problem.count[i];
            sharedCacheStrategy.push_back(new CLATCache(rowLength));
            cacheSize.push_back(min(CACHE_SIZE * 1024 * 256 / rowLength / 3, rowLength));
            printf("shared cache %d size=%d, #samples in class %d=%d\n", i, cacheSize[i], i, rowLength);
            if (cacheSize[i] < problem.count[i]) canPreComputeSharedCache = false;
            sharedCacheStrategy[i]->SetCacheSize(cacheSize[i]);
            sharedCacheStrategy[i]->InitializeCache(cacheSize[i], rowLength);
            hostSharedCache.push_back(new float_point[cacheSize[i] * rowLength]);
        }
        if (canPreComputeSharedCache) {
            printf("cache is large enough, pre-computing shared cache\n");
            SubHessianCalculater::preComputeSharedCache(hostSharedCache, problem, param);
        } else {
            if (!preComputeInHost)
                printf("compute shared kernels on-the-fly\n");
            else
                printf("use pre-compute hessian matrix in host\n");
        }
    }
}

GpuCache::~GpuCache() {
    if(binary){
        delete sharedCacheStrategy[0];
    } else {
        for (int i = 0; i < problem.getNumOfClasses(); ++i) {
            delete sharedCacheStrategy[i];
            delete[] hostSharedCache[i];
        }
    }
//    checkCudaErrors(cudaFreeHost(hostHessianMatrix));
}

void GpuCache::getHessianRow(int rowIndex, float_point *devHessianRow) {
    if(binary){
        if(canPreComputeSharedCache){
            checkCudaErrors(cudaMemcpy(devHessianRow,
                                       devSharedCache[0] + rowIndex * numOfElementEachRowInCache[0],
                                       sizeof(float_point) * problem.getNumOfSamples(),
                                       cudaMemcpyDeviceToDevice));
        }
    } else {

        int originalLabel = subProblem->originalLabel[rowIndex]; //label in 0,1,2,3,4,...
        int originalIndex = subProblem->originalIndex[rowIndex];
        int label = 1 - (subProblem->v_nLabels[rowIndex] + 1) / 2; //map +1 -1 to 0 1
        int theOtherLabel = subProblem->label[1 - label];
        int sharedCacheStart = subProblem->start[label];
        int uniqueCacheStart = subProblem->start[1 - label];
        int sharedCacheCount = subProblem->count[label];
        int uniqueCacheCount = subProblem->count[1 - label];
        int uniqueCacheOffset = -subProblem->start[label];//TODO optimize here
        int sharedCacheOffset = -subProblem->start[label];

        int cacheLocation;
        bool cacheFull = false;
        bool cacheHit;

        //query unique cache
        if (canPreComputeUniqueCache) {
            cacheLocation = rowIndex + uniqueCacheOffset;
        } else {
            cacheHit = uniqueCacheStrategy[label]->GetDataFromCache(rowIndex + uniqueCacheOffset, cacheLocation,
                                                                    cacheFull);
            if (!cacheHit) {
                if (cacheFull)
                    uniqueCacheStrategy[label]->ReplaceExpired(rowIndex + uniqueCacheOffset, cacheLocation, NULL);

                //unique cache position for this row
                float_point *tempUniqueCachePos = devUniqueCache[label] +
                                                  cacheLocation * numOfElementEachRowInUniqueCache[label];
                if (preComputeInHost)
                    checkCudaErrors(cudaMemcpy(tempUniqueCachePos,
                                               hostHessianMatrix
                                               + problem.getNumOfSamples() *
                                                 (problem.start[originalLabel] + rowIndex + sharedCacheOffset)
                                               + problem.start[theOtherLabel],
                                               uniqueCacheCount * sizeof(float_point),
                                               cudaMemcpyHostToDevice));
                else
                    hessianCalculator->ReadRow(rowIndex, tempUniqueCachePos, uniqueCacheStart,
                                               uniqueCacheStart + uniqueCacheCount);
            }
        }
        checkCudaErrors(cudaMemcpy(
                devHessianRow + uniqueCacheStart,
                devUniqueCache[label] + cacheLocation * numOfElementEachRowInUniqueCache[label],
                sizeof(float_point) * uniqueCacheCount,
                cudaMemcpyDeviceToDevice));

        //query shared cache
        if (canPreComputeSharedCache) {
            cacheLocation = rowIndex + sharedCacheOffset;
        } else {
            cacheHit = sharedCacheStrategy[originalLabel]->GetDataFromCache(rowIndex + sharedCacheOffset, cacheLocation,
                                                                            cacheFull);
            if (!cacheHit) {
                if (cacheFull)
                    sharedCacheStrategy[originalLabel]->ReplaceExpired(rowIndex + sharedCacheOffset, cacheLocation,
                                                                       NULL);
                //shared cache position
                float_point *tempSharedCachePos = devSharedCache[originalLabel] +
                                                  cacheLocation * numOfElementEachRowInCache[originalLabel];
                if (preComputeInHost)
                    checkCudaErrors(cudaMemcpy(tempSharedCachePos,
                                               hostHessianMatrix
                                               + problem.getNumOfSamples() *
                                                 (problem.start[originalLabel] + rowIndex + sharedCacheOffset)
                                               + problem.start[originalLabel],
                                               sharedCacheCount * sizeof(float_point),
                                               cudaMemcpyHostToDevice));
                else
                    hessianCalculator->ReadRow(rowIndex, tempSharedCachePos, sharedCacheStart,
                                               sharedCacheStart + sharedCacheCount);
            }
        }
        checkCudaErrors(cudaMemcpy(
                devHessianRow + sharedCacheStart,
                devSharedCache[originalLabel] + cacheLocation * numOfElementEachRowInCache[originalLabel],
                sizeof(float_point) * sharedCacheCount,
                cudaMemcpyDeviceToDevice));
    }
}
