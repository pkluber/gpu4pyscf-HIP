#include "hip/hip_runtime.h"
/*
 * Copyright 2021-2024 The PySCF Developers. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <dlfcn.h>
#include <hip/hip_runtime.h>
#include "libxc.h"
#include "gint/cuda_alloc.cuh"

#define THREADS 256

// Up to order = 2, do_exc = True, do_vxc = True, do_fxc = True, do_kxc = False, do_lxc = False
#define ADD_LDA if(out->zk     != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->zk, out_lda->zk, coef, np, dim->zk); \
                if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vrho, out_lda->vrho, coef, np, dim->vrho); \
                if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rho2, out_lda->v2rho2, coef, np, dim->v2rho2);

#define ADD_GGA if(out->zk     != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->zk, out_gga->zk, coef, np, dim->zk); \
                if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vrho, out_gga->vrho, coef, np, dim->vrho); \
                if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vsigma, out_gga->vsigma, coef, np, dim->vsigma); \
                if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rho2, out_gga->v2rho2, coef, np, dim->v2rho2); \
                if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rhosigma, out_gga->v2rhosigma, coef, np, dim->v2rhosigma); \
                if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2sigma2, out_gga->v2sigma2, coef, np, dim->v2sigma2);

#define ADD_MGGA if(out->zk     != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->zk, out_mgga->zk, coef, np, dim->zk); \
                 if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vrho, out_mgga->vrho, coef, np, dim->vrho); \
                 if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vsigma, out_mgga->vsigma, coef, np, dim->vsigma); \
                 if(out->vrho   != NULL && out->vlapl != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vlapl, out_mgga->vlapl, coef, np, dim->vlapl); \
                 if(out->vrho   != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->vtau, out_mgga->vtau, coef, np, dim->vtau); \
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rho2, out_mgga->v2rho2, coef, np, dim->v2rho2); \
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rhosigma, out_mgga->v2rhosigma, coef, np, dim->v2rhosigma); \
                 if(out->v2rho2 != NULL && out->v2rholapl != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rholapl, out_mgga->v2rholapl, coef, np, dim->v2rholapl); \
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2rhotau, out_mgga->v2rhotau, coef, np, dim->v2rhotau); \
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2sigma2, out_mgga->v2sigma2, coef, np, dim->v2sigma2);\
                 if(out->v2rho2 != NULL && out->v2sigmalapl != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2sigmalapl, out_mgga->v2sigmalapl, coef, np, dim->v2sigmalapl);\
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2sigmatau, out_mgga->v2sigmatau, coef, np, dim->v2sigmatau);\
                 if(out->v2rho2 != NULL && out->v2lapl2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2lapl2, out_mgga->v2lapl2, coef, np, dim->v2lapl2);\
                 if(out->v2rho2 != NULL && out->v2lapltau != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2lapltau, out_mgga->v2lapltau, coef, np, dim->v2lapltau);\
                 if(out->v2rho2 != NULL) _add_out<<<blocks, threads, 0, stream>>>(out->v2tau2, out_mgga->v2tau2, coef, np, dim->v2tau2);

__global__
static void _add_out(double *out, const double *buf, double coef, int np, int dim){
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < np) {
        #pragma unroll
        for (int j = 0; j < dim; j++){
            int idx = i + j * np;
            out[idx] += coef * buf[idx];
        }
    }
}

extern "C" {

__host__
void _memset_lda(xc_lda_out_params *out, int order, int np, const xc_dimensions *dim){
    if(order >= 0) hipMemset(out->zk, 0, sizeof(double)*np*dim->zk);
    if(order >= 1) hipMemset(out->vrho, 0, sizeof(double)*np*dim->vrho);
    if(order >= 2) hipMemset(out->v2rho2, 0, sizeof(double)*np*dim->v2rho2);
    if(order >= 3) hipMemset(out->v3rho3, 0, sizeof(double)*np*dim->v3rho3);
    if(order >= 4) hipMemset(out->v4rho4, 0, sizeof(double)*np*dim->v4rho4);
}

__host__
void _memset_gga(xc_gga_out_params *out, int order, int np, const xc_dimensions *dim){
    if(order >= 0) hipMemset(out->zk, 0, sizeof(double)*np*dim->zk);
    if(order >= 1) {
        hipMemset(out->vrho, 0, sizeof(double)*np*dim->vrho);
        hipMemset(out->vsigma, 0, sizeof(double)*np*dim->vsigma); // (sigma, lapl, tau)
    }
    if(order >= 2) {
        hipMemset(out->v2rho2, 0, sizeof(double)*np*dim->v2rho2);
        hipMemset(out->v2rhosigma, 0, sizeof(double)*np*dim->v2rhosigma);
        hipMemset(out->v2sigma2, 0, sizeof(double)*np*dim->v2sigma2);
    }
    if(order >= 3) {
        hipMemset(out->v3rho3,       0, sizeof(double)*np*dim->v3rho3);
        hipMemset(out->v3rho2sigma,  0, sizeof(double)*np*dim->v3rho2sigma);
        hipMemset(out->v3rhosigma2,  0, sizeof(double)*np*dim->v3rhosigma2);
        hipMemset(out->v3sigma3,     0, sizeof(double)*np*dim->v3sigma3);
    }
    if(order >= 4) {
        hipMemset(out->v4rho4,       0, sizeof(double)*np*dim->v4rho4);
        hipMemset(out->v4rho3sigma,  0, sizeof(double)*np*dim->v4rho3sigma);
        hipMemset(out->v4rho2sigma2, 0, sizeof(double)*np*dim->v4rho2sigma2);
        hipMemset(out->v4rhosigma3,  0, sizeof(double)*np*dim->v4rhosigma3);
        hipMemset(out->v4sigma4,     0, sizeof(double)*np*dim->v4sigma4);
    }
}

__host__
void _memset_mgga(xc_mgga_out_params *out, int order, int np, const xc_dimensions *dim){
    if(order >= 0) hipMemset(out->zk, 0, sizeof(double)*np*dim->zk);

    if(order >= 1) {
        hipMemset(out->vrho, 0, sizeof(double)*np*dim->vrho);
        hipMemset(out->vsigma, 0, sizeof(double)*np*dim->vsigma);
        hipMemset(out->vtau, 0, sizeof(double)*np*dim->vtau);
        if(out->vlapl != NULL) hipMemset(out->vlapl, 0, sizeof(double)*np*dim->vlapl); // (sigma, lapl, tau)
    }

    if(order >= 2) {
        hipMemset(out->v2rho2, 0, sizeof(double)*np*dim->v2rho2);
        hipMemset(out->v2rhosigma, 0, sizeof(double)*np*dim->v2rhosigma);
        hipMemset(out->v2rhotau, 0, sizeof(double)*np*dim->v2rhotau);
        hipMemset(out->v2sigma2, 0, sizeof(double)*np*dim->v2sigma2);
        hipMemset(out->v2sigmatau, 0, sizeof(double)*np*dim->v2sigmatau);
        hipMemset(out->v2tau2, 0, sizeof(double)*np*dim->v2tau2);
        if(out->v2rholapl != NULL) hipMemset(out->v2rholapl, 0, sizeof(double)*np*dim->v2rholapl);
        if(out->v2sigmalapl != NULL) hipMemset(out->v2sigmalapl, 0, sizeof(double)*np*dim->v2sigmalapl);
        if(out->v2lapl2 != NULL) hipMemset(out->v2lapl2, 0, sizeof(double)*np*dim->v2lapl2);
        if(out->v2lapltau != NULL) hipMemset(out->v2lapltau, 0, sizeof(double)*np*dim->v2lapltau);
    }

    if (order >= 3) {
        hipMemset(out->v3rho3        , 0, sizeof(double)*np*dim->v3rho3);
        hipMemset(out->v3rho2sigma   , 0, sizeof(double)*np*dim->v3rho2sigma);
        hipMemset(out->v3rho2tau     , 0, sizeof(double)*np*dim->v3rho2tau);
        hipMemset(out->v3rhosigma2   , 0, sizeof(double)*np*dim->v3rhosigma2);
        hipMemset(out->v3rhosigmatau , 0, sizeof(double)*np*dim->v3rhosigmatau);
        hipMemset(out->v3rhotau2     , 0, sizeof(double)*np*dim->v3rhotau2);
        hipMemset(out->v3sigma3      , 0, sizeof(double)*np*dim->v3sigma3);
        hipMemset(out->v3sigma2tau   , 0, sizeof(double)*np*dim->v3sigma2tau);
        hipMemset(out->v3sigmatau2   , 0, sizeof(double)*np*dim->v3sigmatau2);
        hipMemset(out->v3tau3        , 0, sizeof(double)*np*dim->v3tau3);
        if (out->v3rho2lapl    != NULL) hipMemset(out->v3rho2lapl    , 0, sizeof(double)*np*dim->v3rho2lapl);
        if (out->v3rhosigmalapl!= NULL) hipMemset(out->v3rhosigmalapl, 0, sizeof(double)*np*dim->v3rhosigmalapl);
        if (out->v3rholapl2    != NULL) hipMemset(out->v3rholapl2    , 0, sizeof(double)*np*dim->v3rholapl2);
        if (out->v3rholapltau  != NULL) hipMemset(out->v3rholapltau  , 0, sizeof(double)*np*dim->v3rholapltau);
        if (out->v3sigma2lapl  != NULL) hipMemset(out->v3sigma2lapl  , 0, sizeof(double)*np*dim->v3sigma2lapl);
        if (out->v3sigmalapl2  != NULL) hipMemset(out->v3sigmalapl2  , 0, sizeof(double)*np*dim->v3sigmalapl2);
        if (out->v3sigmalapltau!= NULL) hipMemset(out->v3sigmalapltau, 0, sizeof(double)*np*dim->v3sigmalapltau);
        if (out->v3lapl3       != NULL) hipMemset(out->v3lapl3       , 0, sizeof(double)*np*dim->v3lapl3);
        if (out->v3lapl2tau    != NULL) hipMemset(out->v3lapl2tau    , 0, sizeof(double)*np*dim->v3lapl2tau);
        if (out->v3lapltau2    != NULL) hipMemset(out->v3lapltau2    , 0, sizeof(double)*np*dim->v3lapltau2);
    }

    if (order >= 4) {
        hipMemset(out->v4rho4           , 0, sizeof(double)*np*dim->v4rho4);
        hipMemset(out->v4rho3sigma      , 0, sizeof(double)*np*dim->v4rho3sigma);
        hipMemset(out->v4rho3tau        , 0, sizeof(double)*np*dim->v4rho3tau);
        hipMemset(out->v4rho2sigma2     , 0, sizeof(double)*np*dim->v4rho2sigma2);
        hipMemset(out->v4rho2sigmatau   , 0, sizeof(double)*np*dim->v4rho2sigmatau);
        hipMemset(out->v4rho2tau2       , 0, sizeof(double)*np*dim->v4rho2tau2);
        hipMemset(out->v4rhosigma3      , 0, sizeof(double)*np*dim->v4rhosigma3);
        hipMemset(out->v4rhosigma2tau   , 0, sizeof(double)*np*dim->v4rhosigma2tau);
        hipMemset(out->v4rhosigmatau2   , 0, sizeof(double)*np*dim->v4rhosigmatau2);
        hipMemset(out->v4rhotau3        , 0, sizeof(double)*np*dim->v4rhotau3);
        hipMemset(out->v4sigma4         , 0, sizeof(double)*np*dim->v4sigma4);
        hipMemset(out->v4sigma3tau      , 0, sizeof(double)*np*dim->v4sigma3tau);
        hipMemset(out->v4sigma2tau2     , 0, sizeof(double)*np*dim->v4sigma2tau2);
        hipMemset(out->v4sigmatau3      , 0, sizeof(double)*np*dim->v4sigmatau3);
        hipMemset(out->v4tau4           , 0, sizeof(double)*np*dim->v4tau4);
        if (out->v4rho3lapl       != NULL) hipMemset(out->v4rho3lapl       , 0, sizeof(double)*np*dim->v4rho3lapl);
        if (out->v4rho2sigmalapl  != NULL) hipMemset(out->v4rho2sigmalapl  , 0, sizeof(double)*np*dim->v4rho2sigmalapl);
        if (out->v4rho2lapl2      != NULL) hipMemset(out->v4rho2lapl2      , 0, sizeof(double)*np*dim->v4rho2lapl2);
        if (out->v4rho2lapltau    != NULL) hipMemset(out->v4rho2lapltau    , 0, sizeof(double)*np*dim->v4rho2lapltau);
        if (out->v4rhosigma2lapl  != NULL) hipMemset(out->v4rhosigma2lapl  , 0, sizeof(double)*np*dim->v4rhosigma2lapl);
        if (out->v4rhosigmalapl2  != NULL) hipMemset(out->v4rhosigmalapl2  , 0, sizeof(double)*np*dim->v4rhosigmalapl2);
        if (out->v4rhosigmalapltau!= NULL) hipMemset(out->v4rhosigmalapltau, 0, sizeof(double)*np*dim->v4rhosigmalapltau);
        if (out->v4rholapl3       != NULL) hipMemset(out->v4rholapl3       , 0, sizeof(double)*np*dim->v4rholapl3);
        if (out->v4rholapl2tau    != NULL) hipMemset(out->v4rholapl2tau    , 0, sizeof(double)*np*dim->v4rholapl2tau);
        if (out->v4rholapltau2    != NULL) hipMemset(out->v4rholapltau2    , 0, sizeof(double)*np*dim->v4rholapltau2);
        if (out->v4sigma3lapl     != NULL) hipMemset(out->v4sigma3lapl     , 0, sizeof(double)*np*dim->v4sigma3lapl);
        if (out->v4sigma2lapl2    != NULL) hipMemset(out->v4sigma2lapl2    , 0, sizeof(double)*np*dim->v4sigma2lapl2);
        if (out->v4sigma2lapltau  != NULL) hipMemset(out->v4sigma2lapltau  , 0, sizeof(double)*np*dim->v4sigma2lapltau);
        if (out->v4sigmalapl3     != NULL) hipMemset(out->v4sigmalapl3     , 0, sizeof(double)*np*dim->v4sigmalapl3);
        if (out->v4sigmalapl2tau  != NULL) hipMemset(out->v4sigmalapl2tau  , 0, sizeof(double)*np*dim->v4sigmalapl2tau);
        if (out->v4sigmalapltau2  != NULL) hipMemset(out->v4sigmalapltau2  , 0, sizeof(double)*np*dim->v4sigmalapltau2);
        if (out->v4lapl4          != NULL) hipMemset(out->v4lapl4          , 0, sizeof(double)*np*dim->v4lapl4);
        if (out->v4lapl3tau       != NULL) hipMemset(out->v4lapl3tau       , 0, sizeof(double)*np*dim->v4lapl3tau);
        if (out->v4lapl2tau2      != NULL) hipMemset(out->v4lapl2tau2      , 0, sizeof(double)*np*dim->v4lapl2tau2);
        if (out->v4lapltau3       != NULL) hipMemset(out->v4lapltau3       , 0, sizeof(double)*np*dim->v4lapltau3);
    }
}

__host__
int _xc_lda(const xc_func_type *func, int np, int order, const double *rho,
            xc_lda_out_params *out){
    if(func->info->lda == NULL){
        fprintf(stderr, "Nested xc functional is not supported\n");
        return 1;
    }
    //xc_dimensions* dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    if(order < 0) return 0;
    const xc_dimensions *dim = &(func->dim);
    _memset_lda(out, order, np, dim);
    //FREE(dim);

    if(func->info->lda != NULL){
        if(func->nspin == XC_UNPOLARIZED){
            if(func->info->lda->unpol[order] != NULL)
                func->info->lda->unpol[order](func, np, rho, out);
        }else{
            if(func->info->lda->pol[order] != NULL)
                func->info->lda->pol[order](func, np, rho, out);
        }
    }
    hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "CUDA Error of xc lda: %s\n", hipGetErrorString(err));
        return 1;
    }
    return 0;
}

__host__
int _xc_gga(const xc_func_type *func, int np, int order, const double *rho, const double *sigma,
            xc_gga_out_params *out){
    
    if(func->info->gga == NULL){
        fprintf(stderr, "Nested xc functional is not supported\n");
        return 1;
    }
        
    //xc_dimensions* dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    if(order < 0) return 0;
    const xc_dimensions *dim = &(func->dim);
    _memset_gga(out, order, np, dim);
    //FREE(dim);
    
    hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "CUDA Error of memset_gga: %s\n", hipGetErrorString(err));
        return 1;
    }

    /* call the GGA routines */
    if(func->info->gga != NULL){
        if(func->nspin == XC_UNPOLARIZED){
            if(func->info->gga->unpol[order] != NULL)
                func->info->gga->unpol[order](func, np, rho, sigma, out);
        }else{
            if(func->info->gga->pol[order] != NULL)
                func->info->gga->pol[order](func, np, rho, sigma, out);
        }
    }
    err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "CUDA Error of xc_gga: %s\n", hipGetErrorString(err));
        return 1;
    }
    return 0;
}

__host__
int _xc_mgga(const xc_func_type *func, int np, int order, const double *rho, const double *sigma,
            const double *lapl, const double *tau,
            xc_mgga_out_params *out){
    if(func->info->mgga == NULL){
        fprintf(stderr, "Nested xc functional is not supported\n");
        return 1;
    }
    
    //xc_dimensions* dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    if(order < 0) return 0;
    const xc_dimensions *dim = &(func->dim);
    _memset_mgga(out, order, np, dim);
    //FREE(dim);

    hipError_t err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "CUDA Error of memset mgga: %s\n", hipGetErrorString(err));
        return 1;
    }

    /* call the mGGA routines */
    if(func->info->mgga != NULL){
        if(func->nspin == XC_UNPOLARIZED){
            if(func->info->mgga->unpol[order] != NULL)
                func->info->mgga->unpol[order](func, np, rho, sigma, lapl, tau, out);
        }else{
            if(func->info->mgga->pol[order] != NULL)
                func->info->mgga->pol[order](func, np, rho, sigma, lapl, tau, out);
        }
    }
    err = hipGetLastError();
    if (err != hipSuccess) {
        fprintf(stderr, "CUDA Error of xc mgga: %s\n", hipGetErrorString(err));
        return 1;
    }
    return 0;
}

__host__
int GDFT_xc_lda(hipStream_t stream,
    const xc_func_type *func, int np, const double *rho,
    xc_lda_out_params *out, xc_lda_out_params *buf)
{
    int ierr = 0;
     
    int order = -1;
    if(out->zk     != NULL) order = 0;
    if(out->vrho   != NULL) order = 1;
    if(out->v2rho2 != NULL) order = 2;
    if(out->v3rho3 != NULL) order = 3;
    if(out->v4rho4 != NULL) order = 4;

    // If the functional is not a mix
    if(func->info->lda != NULL){
        ierr = _xc_lda(func, np, order, rho, out);
        return ierr;
    }

    // If the functional is a mix of multiple functionals (more common, such as B3LYP)
    if(func->mix_coef == NULL){
        return ierr;
    }
    int n_func_aux = func->n_func_aux;
    //xc_dimensions* dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    const xc_dimensions *dim = &(func->dim);
    _memset_lda(out, order, np, dim);
    //FREE(dim);

    dim3 threads(THREADS);
    dim3 blocks((np+THREADS-1)/THREADS);
    
    for (int ii=0; ii< n_func_aux; ii++){
        xc_func_type *aux = func->func_aux[ii];
    	double coef = func->mix_coef[ii];
	
	    /* Evaluate the functional */
        switch(aux->info->family){
            case XC_FAMILY_LDA:{
                xc_lda_out_params *out_lda = (xc_lda_out_params *)(buf);
                ierr = _xc_lda(aux, np, order, rho, out_lda);
                ADD_LDA;
                break;
            }
        }
    }
    return ierr;
}

__host__
int GDFT_xc_gga(hipStream_t stream,
    const xc_func_type *func, int np, const double *rho, const double *sigma,
    xc_gga_out_params *out, xc_gga_out_params *buf)
{
    int order = -1;
    if(out->zk     != NULL) order = 0;
    if(out->vrho   != NULL) order = 1;
    if(out->v2rho2 != NULL) order = 2;
    if(out->v3rho3 != NULL) order = 3;
    if(out->v4rho4 != NULL) order = 4;

    // If the functional is not a mix
    int ierr = 0;
    if(func->info->gga != NULL){
        ierr = _xc_gga(func, np, order, rho, sigma, out);
        return ierr;
    }

    // If the functional is a mix of multiple functionals (more common, such as B3LYP)
    if(func->mix_coef == NULL){
        return ierr;
    }
    int n_func_aux = func->n_func_aux;
    //xc_dimensions *dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    const xc_dimensions *dim = &(func->dim);
    _memset_gga(out, order, np, dim);
    //FREE(dim);

    dim3 threads(THREADS);
    dim3 blocks((np+THREADS-1)/THREADS);
    for (int ii=0; ii< n_func_aux; ii++){
	    xc_func_type *aux = func->func_aux[ii];
        double coef = func->mix_coef[ii];

	    /* Evaluate the functional */
        switch(aux->info->family){
            case XC_FAMILY_LDA:{
                xc_lda_out_params *out_lda = (xc_lda_out_params *)(buf);
		        ierr = _xc_lda(aux, np, order, rho, out_lda);
		        ADD_LDA;
                break;
            }
            case XC_FAMILY_GGA:{
                xc_gga_out_params *out_gga = (xc_gga_out_params *)(buf);
		        ierr = _xc_gga(aux, np, order, rho, sigma, out_gga);
		        ADD_GGA;
                break;
            }
        }
    }
    return ierr;
}

__host__
int GDFT_xc_mgga(hipStream_t stream,
        const xc_func_type *func, int np,
        const double *rho, const double *sigma, const double *lapl, const double *tau,
        xc_mgga_out_params *out, xc_mgga_out_params *buf)
{
    int order = -1;

    if(out->zk     != NULL) order = 0;
    if(out->vrho   != NULL) order = 1;
    if(out->v2rho2 != NULL) order = 2;
    if(out->v3rho3 != NULL) order = 3;
    if(out->v4rho4 != NULL) order = 4;

    int ierr = 0;
    // If the functional is not a mix
    if(func->info->mgga != NULL){
        ierr = _xc_mgga(func, np, order, rho, sigma, lapl, tau, out);
        return ierr;
    }

    // If the functional is a mix of multiple functionals (more common, such as B3LYP)
    if(func->mix_coef == NULL){
        return ierr;
    }
    int n_func_aux = func->n_func_aux;
    //xc_dimensions *dim = (xc_dimensions *) malloc(sizeof(xc_dimensions));
    //memcpy(dim, &(func->dim), sizeof(xc_dimensions));
    //DEVICE_INIT(xc_dimensions, dim, &(func->dim), 1);
    const xc_dimensions *dim = &(func->dim);
    _memset_mgga(out, order, np, dim);
    //FREE(dim);

    dim3 threads(THREADS);
    dim3 blocks((np+THREADS-1)/THREADS);
    
    for (int ii=0; ii< n_func_aux; ii++){
    	xc_func_type *aux = func->func_aux[ii];
        double coef = func->mix_coef[ii];
	
        /* Evaluate the functional */
        switch(aux->info->family){
            case XC_FAMILY_LDA:{
                xc_lda_out_params *out_lda = (xc_lda_out_params *)(buf);
                ierr = _xc_lda(aux, np, order, rho, out_lda);
                ADD_LDA;
                break;
            }
            case XC_FAMILY_GGA:{
                xc_gga_out_params *out_gga = (xc_gga_out_params *)(buf);
                ierr = _xc_gga(aux, np, order, rho, sigma, out_gga);
                ADD_GGA;
                break;
            }
            case XC_FAMILY_MGGA:{
                xc_mgga_out_params *out_mgga = (xc_mgga_out_params *)(buf);
                ierr = _xc_mgga(aux, np, order, rho, sigma, lapl, tau, out_mgga);
                ADD_MGGA;
                break;
            }
        }
    }
    return ierr;
}

}
