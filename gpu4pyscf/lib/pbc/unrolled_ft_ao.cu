#include "hip/hip_runtime.h"
/*
 * Copyright 2024-2025 The PySCF Developers. All Rights Reserved.
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
#include <hip/hip_runtime.h>
#include <hip/hip_runtime.h>
#include "gvhf-rys/vhf.cuh"
#include "ft_ao.cuh"
#define OVERLAP_FAC     5.56832799683170787
#define OF_COMPLEX      2


#if CUDA_VERSION >= 12040
__global__ __maxnreg__(64) static
#else
__global__ static
#endif
void ft_ao_unrolled_00(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            xyR = fac * 1;
            gout0R += xyR * vrr_0zR;
            gout0I += xyR * vrr_0zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
    }
}

#if CUDA_VERSION >= 12040
__global__ __maxnreg__(128) static
#else
__global__ static
#endif
void ft_ao_unrolled_01(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = fac * 1;
            gout2R += xyR * hrr_01zR;
            gout2I += xyR * hrr_01zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
    }
}

#if CUDA_VERSION >= 12040
__global__ __maxnreg__(128) static
#else
__global__ static
#endif
void ft_ao_unrolled_02(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double hrr_11xR = vrr_2xR - xjxi * vrr_1xR;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double hrr_02xR = hrr_11xR - xjxi * hrr_01xR;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            double hrr_11xI = vrr_2xI - xjxi * vrr_1xI;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            double hrr_02xI = hrr_11xI - xjxi * hrr_01xI;
            xyR = hrr_02xR * 1;
            xyI = hrr_02xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = hrr_01xR * hrr_01yR - hrr_01xI * hrr_01yI;
            xyI = hrr_01xR * hrr_01yI + hrr_01xI * hrr_01yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout2R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout2I += xyR * hrr_01zI + xyI * hrr_01zR;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double hrr_11yR = vrr_2yR - yjyi * vrr_1yR;
            double hrr_02yR = hrr_11yR - yjyi * hrr_01yR;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            double hrr_11yI = vrr_2yI - yjyi * vrr_1yI;
            double hrr_02yI = hrr_11yI - yjyi * hrr_01yI;
            xyR = fac * hrr_02yR;
            xyI = fac * hrr_02yI;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout4R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout4I += xyR * hrr_01zI + xyI * hrr_01zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double hrr_11zR = vrr_2zR - zjzi * vrr_1zR;
            double hrr_02zR = hrr_11zR - zjzi * hrr_01zR;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            double hrr_11zI = vrr_2zI - zjzi * vrr_1zI;
            double hrr_02zI = hrr_11zI - zjzi * hrr_01zI;
            xyR = fac * 1;
            gout5R += xyR * hrr_02zR;
            gout5I += xyR * hrr_02zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (0*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (0*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (0*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
    }
}

#if CUDA_VERSION >= 12040
__global__ __maxnreg__(128) static
#else
__global__ static
#endif
void ft_ao_unrolled_10(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = fac * 1;
            gout2R += xyR * vrr_1zR;
            gout2I += xyR * vrr_1zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
    }
}

#if CUDA_VERSION >= 12040
__global__ __maxnreg__(128) static
#else
__global__ static
#endif
void ft_ao_unrolled_11(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double gout6R = 0;
    double gout6I = 0;
    double gout7R = 0;
    double gout7I = 0;
    double gout8R = 0;
    double gout8I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double hrr_11xR = vrr_2xR - xjxi * vrr_1xR;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            double hrr_11xI = vrr_2xI - xjxi * vrr_1xI;
            xyR = hrr_11xR * 1;
            xyI = hrr_11xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = hrr_01xR * vrr_1yR - hrr_01xI * vrr_1yI;
            xyI = hrr_01xR * vrr_1yI + hrr_01xI * vrr_1yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout2R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout2I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = vrr_1xR * hrr_01yR - vrr_1xI * hrr_01yI;
            xyI = vrr_1xR * hrr_01yI + vrr_1xI * hrr_01yR;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double hrr_11yR = vrr_2yR - yjyi * vrr_1yR;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            double hrr_11yI = vrr_2yI - yjyi * vrr_1yI;
            xyR = fac * hrr_11yR;
            xyI = fac * hrr_11yI;
            gout4R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout4I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout5R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout5I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout6R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout6I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout7R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout7I += xyR * hrr_01zI + xyI * hrr_01zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double hrr_11zR = vrr_2zR - zjzi * vrr_1zR;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            double hrr_11zI = vrr_2zI - zjzi * vrr_1zI;
            xyR = fac * 1;
            gout8R += xyR * hrr_11zR;
            gout8I += xyR * hrr_11zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout6R;
        aft_tensor[addr*2+1] = gout6I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (1*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (1*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout7R;
        aft_tensor[addr*2+1] = gout7I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (2*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
        addr = (2*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout8R;
        aft_tensor[addr*2+1] = gout8I;
    }
}

__global__ static
void ft_ao_unrolled_12(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double gout6R = 0;
    double gout6I = 0;
    double gout7R = 0;
    double gout7I = 0;
    double gout8R = 0;
    double gout8I = 0;
    double gout9R = 0;
    double gout9I = 0;
    double gout10R = 0;
    double gout10I = 0;
    double gout11R = 0;
    double gout11I = 0;
    double gout12R = 0;
    double gout12I = 0;
    double gout13R = 0;
    double gout13I = 0;
    double gout14R = 0;
    double gout14I = 0;
    double gout15R = 0;
    double gout15I = 0;
    double gout16R = 0;
    double gout16I = 0;
    double gout17R = 0;
    double gout17I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            double vrr_3xR = 2*a2 * vrr_1xR + xpaR * vrr_2xR - xpaI * vrr_2xI;
            double hrr_21xR = vrr_3xR - xjxi * vrr_2xR;
            double hrr_11xR = vrr_2xR - xjxi * vrr_1xR;
            double hrr_12xR = hrr_21xR - xjxi * hrr_11xR;
            double vrr_3xI = 2*a2 * vrr_1xI + xpaR * vrr_2xI + xpaI * vrr_2xR;
            double hrr_21xI = vrr_3xI - xjxi * vrr_2xI;
            double hrr_11xI = vrr_2xI - xjxi * vrr_1xI;
            double hrr_12xI = hrr_21xI - xjxi * hrr_11xI;
            xyR = hrr_12xR * 1;
            xyI = hrr_12xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double hrr_02xR = hrr_11xR - xjxi * hrr_01xR;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            double hrr_02xI = hrr_11xI - xjxi * hrr_01xI;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = hrr_02xR * vrr_1yR - hrr_02xI * vrr_1yI;
            xyI = hrr_02xR * vrr_1yI + hrr_02xI * vrr_1yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = hrr_02xR * 1;
            xyI = hrr_02xI * 1;
            gout2R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout2I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = hrr_11xR * hrr_01yR - hrr_11xI * hrr_01yI;
            xyI = hrr_11xR * hrr_01yI + hrr_11xI * hrr_01yR;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double hrr_11yR = vrr_2yR - yjyi * vrr_1yR;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            double hrr_11yI = vrr_2yI - yjyi * vrr_1yI;
            xyR = hrr_01xR * hrr_11yR - hrr_01xI * hrr_11yI;
            xyI = hrr_01xR * hrr_11yI + hrr_01xI * hrr_11yR;
            gout4R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout4I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = hrr_01xR * hrr_01yR - hrr_01xI * hrr_01yI;
            xyI = hrr_01xR * hrr_01yI + hrr_01xI * hrr_01yR;
            gout5R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout5I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = hrr_11xR * 1;
            xyI = hrr_11xI * 1;
            gout6R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout6I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = hrr_01xR * vrr_1yR - hrr_01xI * vrr_1yI;
            xyI = hrr_01xR * vrr_1yI + hrr_01xI * vrr_1yR;
            gout7R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout7I += xyR * hrr_01zI + xyI * hrr_01zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double hrr_11zR = vrr_2zR - zjzi * vrr_1zR;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            double hrr_11zI = vrr_2zI - zjzi * vrr_1zI;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout8R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout8I += xyR * hrr_11zI + xyI * hrr_11zR;
            double hrr_02yR = hrr_11yR - yjyi * hrr_01yR;
            double hrr_02yI = hrr_11yI - yjyi * hrr_01yI;
            xyR = vrr_1xR * hrr_02yR - vrr_1xI * hrr_02yI;
            xyI = vrr_1xR * hrr_02yI + vrr_1xI * hrr_02yR;
            gout9R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout9I += xyR * vrr_0zI + xyI * vrr_0zR;
            double vrr_3yR = 2*a2 * vrr_1yR + ypaR * vrr_2yR - ypaI * vrr_2yI;
            double hrr_21yR = vrr_3yR - yjyi * vrr_2yR;
            double hrr_12yR = hrr_21yR - yjyi * hrr_11yR;
            double vrr_3yI = 2*a2 * vrr_1yI + ypaR * vrr_2yI + ypaI * vrr_2yR;
            double hrr_21yI = vrr_3yI - yjyi * vrr_2yI;
            double hrr_12yI = hrr_21yI - yjyi * hrr_11yI;
            xyR = fac * hrr_12yR;
            xyI = fac * hrr_12yI;
            gout10R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout10I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * hrr_02yR;
            xyI = fac * hrr_02yI;
            gout11R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout11I += xyR * vrr_1zI + xyI * vrr_1zR;
            xyR = vrr_1xR * hrr_01yR - vrr_1xI * hrr_01yI;
            xyI = vrr_1xR * hrr_01yI + vrr_1xI * hrr_01yR;
            gout12R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout12I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = fac * hrr_11yR;
            xyI = fac * hrr_11yI;
            gout13R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout13I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout14R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout14I += xyR * hrr_11zI + xyI * hrr_11zR;
            double hrr_02zR = hrr_11zR - zjzi * hrr_01zR;
            double hrr_02zI = hrr_11zI - zjzi * hrr_01zI;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout15R += xyR * hrr_02zR - xyI * hrr_02zI;
            gout15I += xyR * hrr_02zI + xyI * hrr_02zR;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout16R += xyR * hrr_02zR - xyI * hrr_02zI;
            gout16I += xyR * hrr_02zI + xyI * hrr_02zR;
            double vrr_3zR = 2*a2 * vrr_1zR + zpaR * vrr_2zR - zpaI * vrr_2zI;
            double hrr_21zR = vrr_3zR - zjzi * vrr_2zR;
            double hrr_12zR = hrr_21zR - zjzi * hrr_11zR;
            double vrr_3zI = 2*a2 * vrr_1zI + zpaR * vrr_2zI + zpaI * vrr_2zR;
            double hrr_21zI = vrr_3zI - zjzi * vrr_2zI;
            double hrr_12zI = hrr_21zI - zjzi * hrr_11zI;
            xyR = fac * 1;
            gout17R += xyR * hrr_12zR;
            gout17I += xyR * hrr_12zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout6R;
        aft_tensor[addr*2+1] = gout6I;
        addr = (0*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout9R;
        aft_tensor[addr*2+1] = gout9I;
        addr = (0*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout12R;
        aft_tensor[addr*2+1] = gout12I;
        addr = (0*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout15R;
        aft_tensor[addr*2+1] = gout15I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (1*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (1*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout7R;
        aft_tensor[addr*2+1] = gout7I;
        addr = (1*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout10R;
        aft_tensor[addr*2+1] = gout10I;
        addr = (1*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout13R;
        aft_tensor[addr*2+1] = gout13I;
        addr = (1*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout16R;
        aft_tensor[addr*2+1] = gout16I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (2*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
        addr = (2*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout8R;
        aft_tensor[addr*2+1] = gout8I;
        addr = (2*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout11R;
        aft_tensor[addr*2+1] = gout11I;
        addr = (2*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout14R;
        aft_tensor[addr*2+1] = gout14I;
        addr = (2*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout17R;
        aft_tensor[addr*2+1] = gout17I;
    }
}

#if CUDA_VERSION >= 12040
__global__ __maxnreg__(128) static
#else
__global__ static
#endif
void ft_ao_unrolled_20(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            xyR = vrr_2xR * 1;
            xyI = vrr_2xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = vrr_1xR * vrr_1yR - vrr_1xI * vrr_1yI;
            xyI = vrr_1xR * vrr_1yI + vrr_1xI * vrr_1yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout2R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout2I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            xyR = fac * vrr_2yR;
            xyI = fac * vrr_2yI;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout4R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout4I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            xyR = fac * 1;
            gout5R += xyR * vrr_2zR;
            gout5I += xyR * vrr_2zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (3*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (4*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (5*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
    }
}

__global__ static
void ft_ao_unrolled_21(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double gout6R = 0;
    double gout6I = 0;
    double gout7R = 0;
    double gout7I = 0;
    double gout8R = 0;
    double gout8I = 0;
    double gout9R = 0;
    double gout9I = 0;
    double gout10R = 0;
    double gout10I = 0;
    double gout11R = 0;
    double gout11I = 0;
    double gout12R = 0;
    double gout12I = 0;
    double gout13R = 0;
    double gout13I = 0;
    double gout14R = 0;
    double gout14I = 0;
    double gout15R = 0;
    double gout15I = 0;
    double gout16R = 0;
    double gout16I = 0;
    double gout17R = 0;
    double gout17I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            double vrr_3xR = 2*a2 * vrr_1xR + xpaR * vrr_2xR - xpaI * vrr_2xI;
            double hrr_21xR = vrr_3xR - xjxi * vrr_2xR;
            double vrr_3xI = 2*a2 * vrr_1xI + xpaR * vrr_2xI + xpaI * vrr_2xR;
            double hrr_21xI = vrr_3xI - xjxi * vrr_2xI;
            xyR = hrr_21xR * 1;
            xyI = hrr_21xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_11xR = vrr_2xR - xjxi * vrr_1xR;
            double hrr_11xI = vrr_2xI - xjxi * vrr_1xI;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = hrr_11xR * vrr_1yR - hrr_11xI * vrr_1yI;
            xyI = hrr_11xR * vrr_1yI + hrr_11xI * vrr_1yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = hrr_11xR * 1;
            xyI = hrr_11xI * 1;
            gout2R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout2I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            xyR = hrr_01xR * vrr_2yR - hrr_01xI * vrr_2yI;
            xyI = hrr_01xR * vrr_2yI + hrr_01xI * vrr_2yR;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = hrr_01xR * vrr_1yR - hrr_01xI * vrr_1yI;
            xyI = hrr_01xR * vrr_1yI + hrr_01xI * vrr_1yR;
            gout4R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout4I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout5R += xyR * vrr_2zR - xyI * vrr_2zI;
            gout5I += xyR * vrr_2zI + xyI * vrr_2zR;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = vrr_2xR * hrr_01yR - vrr_2xI * hrr_01yI;
            xyI = vrr_2xR * hrr_01yI + vrr_2xI * hrr_01yR;
            gout6R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout6I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_11yR = vrr_2yR - yjyi * vrr_1yR;
            double hrr_11yI = vrr_2yI - yjyi * vrr_1yI;
            xyR = vrr_1xR * hrr_11yR - vrr_1xI * hrr_11yI;
            xyI = vrr_1xR * hrr_11yI + vrr_1xI * hrr_11yR;
            gout7R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout7I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = vrr_1xR * hrr_01yR - vrr_1xI * hrr_01yI;
            xyI = vrr_1xR * hrr_01yI + vrr_1xI * hrr_01yR;
            gout8R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout8I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_3yR = 2*a2 * vrr_1yR + ypaR * vrr_2yR - ypaI * vrr_2yI;
            double hrr_21yR = vrr_3yR - yjyi * vrr_2yR;
            double vrr_3yI = 2*a2 * vrr_1yI + ypaR * vrr_2yI + ypaI * vrr_2yR;
            double hrr_21yI = vrr_3yI - yjyi * vrr_2yI;
            xyR = fac * hrr_21yR;
            xyI = fac * hrr_21yI;
            gout9R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout9I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * hrr_11yR;
            xyI = fac * hrr_11yI;
            gout10R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout10I += xyR * vrr_1zI + xyI * vrr_1zR;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout11R += xyR * vrr_2zR - xyI * vrr_2zI;
            gout11I += xyR * vrr_2zI + xyI * vrr_2zR;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = vrr_2xR * 1;
            xyI = vrr_2xI * 1;
            gout12R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout12I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = vrr_1xR * vrr_1yR - vrr_1xI * vrr_1yI;
            xyI = vrr_1xR * vrr_1yI + vrr_1xI * vrr_1yR;
            gout13R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout13I += xyR * hrr_01zI + xyI * hrr_01zR;
            double hrr_11zR = vrr_2zR - zjzi * vrr_1zR;
            double hrr_11zI = vrr_2zI - zjzi * vrr_1zI;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout14R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout14I += xyR * hrr_11zI + xyI * hrr_11zR;
            xyR = fac * vrr_2yR;
            xyI = fac * vrr_2yI;
            gout15R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout15I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout16R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout16I += xyR * hrr_11zI + xyI * hrr_11zR;
            double vrr_3zR = 2*a2 * vrr_1zR + zpaR * vrr_2zR - zpaI * vrr_2zI;
            double hrr_21zR = vrr_3zR - zjzi * vrr_2zR;
            double vrr_3zI = 2*a2 * vrr_1zI + zpaR * vrr_2zI + zpaI * vrr_2zR;
            double hrr_21zI = vrr_3zI - zjzi * vrr_2zI;
            xyR = fac * 1;
            gout17R += xyR * hrr_21zR;
            gout17I += xyR * hrr_21zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout6R;
        aft_tensor[addr*2+1] = gout6I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout12R;
        aft_tensor[addr*2+1] = gout12I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (1*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout7R;
        aft_tensor[addr*2+1] = gout7I;
        addr = (1*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout13R;
        aft_tensor[addr*2+1] = gout13I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (2*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout8R;
        aft_tensor[addr*2+1] = gout8I;
        addr = (2*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout14R;
        aft_tensor[addr*2+1] = gout14I;
        addr = (3*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (3*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout9R;
        aft_tensor[addr*2+1] = gout9I;
        addr = (3*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout15R;
        aft_tensor[addr*2+1] = gout15I;
        addr = (4*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (4*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout10R;
        aft_tensor[addr*2+1] = gout10I;
        addr = (4*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout16R;
        aft_tensor[addr*2+1] = gout16I;
        addr = (5*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
        addr = (5*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout11R;
        aft_tensor[addr*2+1] = gout11I;
        addr = (5*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout17R;
        aft_tensor[addr*2+1] = gout17I;
    }
}

__global__ static
void ft_ao_unrolled_22(double *out, AFTIntEnvVars envs, AFTBoundsInfo bounds)
{
    int sp_block_id = blockIdx.x;
    int Gv_block_id = blockIdx.y;
    int nGv_per_block = blockDim.x;
    int nsp_per_block = blockDim.y;
    int Gv_id = threadIdx.x;
    int sp_id = threadIdx.y;
    int npairs_ij = bounds.npairs_ij;
    int pair_ij_idx = sp_block_id * nsp_per_block + sp_id;
    if (pair_ij_idx >= npairs_ij) {
        return;
    }
    int nbas = envs.nbas;
    int ish = bounds.ish_in_pair[pair_ij_idx];
    int jsh = bounds.jsh_in_pair[pair_ij_idx];
    int *sp_img_offsets = envs.img_offsets;
    int bas_ij = ish * nbas + jsh;
    int img0 = sp_img_offsets[bas_ij];
    int img1 = sp_img_offsets[bas_ij+1];
    if (img0 >= img1) {
        return;
    }
    int iprim = bounds.iprim;
    int jprim = bounds.jprim;
    int ijprim = iprim * jprim;
    int *atm = envs.atm;
    int *bas = envs.bas;
    double *env = envs.env;
    double *expi = env + bas[ish*BAS_SLOTS+PTR_EXP];
    double *expj = env + bas[jsh*BAS_SLOTS+PTR_EXP];
    double *ci = env + bas[ish*BAS_SLOTS+PTR_COEFF];
    double *cj = env + bas[jsh*BAS_SLOTS+PTR_COEFF];
    int ia = bas[ish*BAS_SLOTS+ATOM_OF];
    int ja = bas[jsh*BAS_SLOTS+ATOM_OF];
    double *ri = env + atm[ia*ATM_SLOTS+PTR_COORD];
    double *rj = env + atm[ja*ATM_SLOTS+PTR_COORD];
    double *img_coords = envs.img_coords;
    int *img_idx = envs.img_idx;
    int nGv = bounds.ngrids;
    double *Gv = bounds.grids + Gv_block_id * nGv_per_block;
    double kx = Gv[Gv_id];
    double ky = Gv[Gv_id + nGv];
    double kz = Gv[Gv_id + nGv * 2];
    double kk = kx * kx + ky * ky + kz * kz;
    double gout0R = 0;
    double gout0I = 0;
    double gout1R = 0;
    double gout1I = 0;
    double gout2R = 0;
    double gout2I = 0;
    double gout3R = 0;
    double gout3I = 0;
    double gout4R = 0;
    double gout4I = 0;
    double gout5R = 0;
    double gout5I = 0;
    double gout6R = 0;
    double gout6I = 0;
    double gout7R = 0;
    double gout7I = 0;
    double gout8R = 0;
    double gout8I = 0;
    double gout9R = 0;
    double gout9I = 0;
    double gout10R = 0;
    double gout10I = 0;
    double gout11R = 0;
    double gout11I = 0;
    double gout12R = 0;
    double gout12I = 0;
    double gout13R = 0;
    double gout13I = 0;
    double gout14R = 0;
    double gout14I = 0;
    double gout15R = 0;
    double gout15I = 0;
    double gout16R = 0;
    double gout16I = 0;
    double gout17R = 0;
    double gout17I = 0;
    double gout18R = 0;
    double gout18I = 0;
    double gout19R = 0;
    double gout19I = 0;
    double gout20R = 0;
    double gout20I = 0;
    double gout21R = 0;
    double gout21I = 0;
    double gout22R = 0;
    double gout22I = 0;
    double gout23R = 0;
    double gout23I = 0;
    double gout24R = 0;
    double gout24I = 0;
    double gout25R = 0;
    double gout25I = 0;
    double gout26R = 0;
    double gout26I = 0;
    double gout27R = 0;
    double gout27I = 0;
    double gout28R = 0;
    double gout28I = 0;
    double gout29R = 0;
    double gout29I = 0;
    double gout30R = 0;
    double gout30I = 0;
    double gout31R = 0;
    double gout31I = 0;
    double gout32R = 0;
    double gout32I = 0;
    double gout33R = 0;
    double gout33I = 0;
    double gout34R = 0;
    double gout34I = 0;
    double gout35R = 0;
    double gout35I = 0;
    double xyR, xyI;
    for (int ijp = 0; ijp < ijprim; ++ijp) {
        int ip = ijp / jprim;
        int jp = ijp % jprim;
        double ai = expi[ip];
        double aj = expj[jp];
        double aij = ai + aj;
        double aj_aij = aj / aij;
        double a2 = .5 / aij;
        double fac = OVERLAP_FAC * ci[ip] * cj[jp] / (aij * sqrt(aij));
        for (int img = img0; img < img1; img++) {
            int img_id = img_idx[img];
            double Lx = img_coords[img_id*3+0];
            double Ly = img_coords[img_id*3+1];
            double Lz = img_coords[img_id*3+2];
            double xjxi = rj[0] + Lx - ri[0];
            double yjyi = rj[1] + Ly - ri[1];
            double zjzi = rj[2] + Lz - ri[2];
            double xij = xjxi * aj_aij + ri[0];
            double yij = yjyi * aj_aij + ri[1];
            double zij = zjzi * aj_aij + ri[2];
            double kR = kx * xij + ky * yij + kz * zij;
            double vrr_0zR;
            double vrr_0zI;
            sincos(-kR, &vrr_0zI, &vrr_0zR);
            double theta_ij = ai * aj_aij;
            double rr = xjxi*xjxi + yjyi*yjyi + zjzi*zjzi;
            double theta_rr = theta_ij*rr + .5*a2*kk;
            double Kab = exp(-theta_rr);
            vrr_0zR *= Kab;
            vrr_0zI *= Kab;
            double xpaR = xjxi * aj_aij;
            double vrr_1xR = xpaR * fac;
            double xpaI = -a2 * Gv[Gv_id+nGv*0];
            double vrr_1xI = xpaI * fac;
            double vrr_2xR = 1*a2 * fac + xpaR * vrr_1xR - xpaI * vrr_1xI;
            double vrr_2xI = 1*a2 * 0 + xpaR * vrr_1xI + xpaI * vrr_1xR;
            double vrr_3xR = 2*a2 * vrr_1xR + xpaR * vrr_2xR - xpaI * vrr_2xI;
            double vrr_3xI = 2*a2 * vrr_1xI + xpaR * vrr_2xI + xpaI * vrr_2xR;
            double vrr_4xR = 3*a2 * vrr_2xR + xpaR * vrr_3xR - xpaI * vrr_3xI;
            double hrr_31xR = vrr_4xR - xjxi * vrr_3xR;
            double hrr_21xR = vrr_3xR - xjxi * vrr_2xR;
            double hrr_22xR = hrr_31xR - xjxi * hrr_21xR;
            double vrr_4xI = 3*a2 * vrr_2xI + xpaR * vrr_3xI + xpaI * vrr_3xR;
            double hrr_31xI = vrr_4xI - xjxi * vrr_3xI;
            double hrr_21xI = vrr_3xI - xjxi * vrr_2xI;
            double hrr_22xI = hrr_31xI - xjxi * hrr_21xI;
            xyR = hrr_22xR * 1;
            xyI = hrr_22xI * 1;
            gout0R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout0I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_11xR = vrr_2xR - xjxi * vrr_1xR;
            double hrr_12xR = hrr_21xR - xjxi * hrr_11xR;
            double hrr_11xI = vrr_2xI - xjxi * vrr_1xI;
            double hrr_12xI = hrr_21xI - xjxi * hrr_11xI;
            double ypaR = yjyi * aj_aij;
            double vrr_1yR = ypaR * 1;
            double ypaI = -a2 * Gv[Gv_id+nGv*1];
            double vrr_1yI = ypaI * 1;
            xyR = hrr_12xR * vrr_1yR - hrr_12xI * vrr_1yI;
            xyI = hrr_12xR * vrr_1yI + hrr_12xI * vrr_1yR;
            gout1R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout1I += xyR * vrr_0zI + xyI * vrr_0zR;
            double zpaR = zjzi * aj_aij;
            double zpaI = -a2 * Gv[Gv_id+nGv*2];
            double vrr_1zR = zpaR * vrr_0zR - zpaI * vrr_0zI;
            double vrr_1zI = zpaR * vrr_0zI + zpaI * vrr_0zR;
            xyR = hrr_12xR * 1;
            xyI = hrr_12xI * 1;
            gout2R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout2I += xyR * vrr_1zI + xyI * vrr_1zR;
            double hrr_01xR = vrr_1xR - xjxi * fac;
            double hrr_02xR = hrr_11xR - xjxi * hrr_01xR;
            double hrr_01xI = vrr_1xI - xjxi * 0;
            double hrr_02xI = hrr_11xI - xjxi * hrr_01xI;
            double vrr_2yR = 1*a2 * 1 + ypaR * vrr_1yR - ypaI * vrr_1yI;
            double vrr_2yI = 1*a2 * 0 + ypaR * vrr_1yI + ypaI * vrr_1yR;
            xyR = hrr_02xR * vrr_2yR - hrr_02xI * vrr_2yI;
            xyI = hrr_02xR * vrr_2yI + hrr_02xI * vrr_2yR;
            gout3R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout3I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = hrr_02xR * vrr_1yR - hrr_02xI * vrr_1yI;
            xyI = hrr_02xR * vrr_1yI + hrr_02xI * vrr_1yR;
            gout4R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout4I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_2zR = 1*a2 * vrr_0zR + zpaR * vrr_1zR - zpaI * vrr_1zI;
            double vrr_2zI = 1*a2 * vrr_0zI + zpaR * vrr_1zI + zpaI * vrr_1zR;
            xyR = hrr_02xR * 1;
            xyI = hrr_02xI * 1;
            gout5R += xyR * vrr_2zR - xyI * vrr_2zI;
            gout5I += xyR * vrr_2zI + xyI * vrr_2zR;
            double hrr_01yR = vrr_1yR - yjyi * 1;
            double hrr_01yI = vrr_1yI - yjyi * 0;
            xyR = hrr_21xR * hrr_01yR - hrr_21xI * hrr_01yI;
            xyI = hrr_21xR * hrr_01yI + hrr_21xI * hrr_01yR;
            gout6R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout6I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_11yR = vrr_2yR - yjyi * vrr_1yR;
            double hrr_11yI = vrr_2yI - yjyi * vrr_1yI;
            xyR = hrr_11xR * hrr_11yR - hrr_11xI * hrr_11yI;
            xyI = hrr_11xR * hrr_11yI + hrr_11xI * hrr_11yR;
            gout7R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout7I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = hrr_11xR * hrr_01yR - hrr_11xI * hrr_01yI;
            xyI = hrr_11xR * hrr_01yI + hrr_11xI * hrr_01yR;
            gout8R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout8I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_3yR = 2*a2 * vrr_1yR + ypaR * vrr_2yR - ypaI * vrr_2yI;
            double hrr_21yR = vrr_3yR - yjyi * vrr_2yR;
            double vrr_3yI = 2*a2 * vrr_1yI + ypaR * vrr_2yI + ypaI * vrr_2yR;
            double hrr_21yI = vrr_3yI - yjyi * vrr_2yI;
            xyR = hrr_01xR * hrr_21yR - hrr_01xI * hrr_21yI;
            xyI = hrr_01xR * hrr_21yI + hrr_01xI * hrr_21yR;
            gout9R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout9I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = hrr_01xR * hrr_11yR - hrr_01xI * hrr_11yI;
            xyI = hrr_01xR * hrr_11yI + hrr_01xI * hrr_11yR;
            gout10R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout10I += xyR * vrr_1zI + xyI * vrr_1zR;
            xyR = hrr_01xR * hrr_01yR - hrr_01xI * hrr_01yI;
            xyI = hrr_01xR * hrr_01yI + hrr_01xI * hrr_01yR;
            gout11R += xyR * vrr_2zR - xyI * vrr_2zI;
            gout11I += xyR * vrr_2zI + xyI * vrr_2zR;
            double hrr_01zR = vrr_1zR - zjzi * vrr_0zR;
            double hrr_01zI = vrr_1zI - zjzi * vrr_0zI;
            xyR = hrr_21xR * 1;
            xyI = hrr_21xI * 1;
            gout12R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout12I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = hrr_11xR * vrr_1yR - hrr_11xI * vrr_1yI;
            xyI = hrr_11xR * vrr_1yI + hrr_11xI * vrr_1yR;
            gout13R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout13I += xyR * hrr_01zI + xyI * hrr_01zR;
            double hrr_11zR = vrr_2zR - zjzi * vrr_1zR;
            double hrr_11zI = vrr_2zI - zjzi * vrr_1zI;
            xyR = hrr_11xR * 1;
            xyI = hrr_11xI * 1;
            gout14R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout14I += xyR * hrr_11zI + xyI * hrr_11zR;
            xyR = hrr_01xR * vrr_2yR - hrr_01xI * vrr_2yI;
            xyI = hrr_01xR * vrr_2yI + hrr_01xI * vrr_2yR;
            gout15R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout15I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = hrr_01xR * vrr_1yR - hrr_01xI * vrr_1yI;
            xyI = hrr_01xR * vrr_1yI + hrr_01xI * vrr_1yR;
            gout16R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout16I += xyR * hrr_11zI + xyI * hrr_11zR;
            double vrr_3zR = 2*a2 * vrr_1zR + zpaR * vrr_2zR - zpaI * vrr_2zI;
            double hrr_21zR = vrr_3zR - zjzi * vrr_2zR;
            double vrr_3zI = 2*a2 * vrr_1zI + zpaR * vrr_2zI + zpaI * vrr_2zR;
            double hrr_21zI = vrr_3zI - zjzi * vrr_2zI;
            xyR = hrr_01xR * 1;
            xyI = hrr_01xI * 1;
            gout17R += xyR * hrr_21zR - xyI * hrr_21zI;
            gout17I += xyR * hrr_21zI + xyI * hrr_21zR;
            double hrr_02yR = hrr_11yR - yjyi * hrr_01yR;
            double hrr_02yI = hrr_11yI - yjyi * hrr_01yI;
            xyR = vrr_2xR * hrr_02yR - vrr_2xI * hrr_02yI;
            xyI = vrr_2xR * hrr_02yI + vrr_2xI * hrr_02yR;
            gout18R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout18I += xyR * vrr_0zI + xyI * vrr_0zR;
            double hrr_12yR = hrr_21yR - yjyi * hrr_11yR;
            double hrr_12yI = hrr_21yI - yjyi * hrr_11yI;
            xyR = vrr_1xR * hrr_12yR - vrr_1xI * hrr_12yI;
            xyI = vrr_1xR * hrr_12yI + vrr_1xI * hrr_12yR;
            gout19R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout19I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = vrr_1xR * hrr_02yR - vrr_1xI * hrr_02yI;
            xyI = vrr_1xR * hrr_02yI + vrr_1xI * hrr_02yR;
            gout20R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout20I += xyR * vrr_1zI + xyI * vrr_1zR;
            double vrr_4yR = 3*a2 * vrr_2yR + ypaR * vrr_3yR - ypaI * vrr_3yI;
            double hrr_31yR = vrr_4yR - yjyi * vrr_3yR;
            double hrr_22yR = hrr_31yR - yjyi * hrr_21yR;
            double vrr_4yI = 3*a2 * vrr_2yI + ypaR * vrr_3yI + ypaI * vrr_3yR;
            double hrr_31yI = vrr_4yI - yjyi * vrr_3yI;
            double hrr_22yI = hrr_31yI - yjyi * hrr_21yI;
            xyR = fac * hrr_22yR;
            xyI = fac * hrr_22yI;
            gout21R += xyR * vrr_0zR - xyI * vrr_0zI;
            gout21I += xyR * vrr_0zI + xyI * vrr_0zR;
            xyR = fac * hrr_12yR;
            xyI = fac * hrr_12yI;
            gout22R += xyR * vrr_1zR - xyI * vrr_1zI;
            gout22I += xyR * vrr_1zI + xyI * vrr_1zR;
            xyR = fac * hrr_02yR;
            xyI = fac * hrr_02yI;
            gout23R += xyR * vrr_2zR - xyI * vrr_2zI;
            gout23I += xyR * vrr_2zI + xyI * vrr_2zR;
            xyR = vrr_2xR * hrr_01yR - vrr_2xI * hrr_01yI;
            xyI = vrr_2xR * hrr_01yI + vrr_2xI * hrr_01yR;
            gout24R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout24I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = vrr_1xR * hrr_11yR - vrr_1xI * hrr_11yI;
            xyI = vrr_1xR * hrr_11yI + vrr_1xI * hrr_11yR;
            gout25R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout25I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = vrr_1xR * hrr_01yR - vrr_1xI * hrr_01yI;
            xyI = vrr_1xR * hrr_01yI + vrr_1xI * hrr_01yR;
            gout26R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout26I += xyR * hrr_11zI + xyI * hrr_11zR;
            xyR = fac * hrr_21yR;
            xyI = fac * hrr_21yI;
            gout27R += xyR * hrr_01zR - xyI * hrr_01zI;
            gout27I += xyR * hrr_01zI + xyI * hrr_01zR;
            xyR = fac * hrr_11yR;
            xyI = fac * hrr_11yI;
            gout28R += xyR * hrr_11zR - xyI * hrr_11zI;
            gout28I += xyR * hrr_11zI + xyI * hrr_11zR;
            xyR = fac * hrr_01yR;
            xyI = fac * hrr_01yI;
            gout29R += xyR * hrr_21zR - xyI * hrr_21zI;
            gout29I += xyR * hrr_21zI + xyI * hrr_21zR;
            double hrr_02zR = hrr_11zR - zjzi * hrr_01zR;
            double hrr_02zI = hrr_11zI - zjzi * hrr_01zI;
            xyR = vrr_2xR * 1;
            xyI = vrr_2xI * 1;
            gout30R += xyR * hrr_02zR - xyI * hrr_02zI;
            gout30I += xyR * hrr_02zI + xyI * hrr_02zR;
            xyR = vrr_1xR * vrr_1yR - vrr_1xI * vrr_1yI;
            xyI = vrr_1xR * vrr_1yI + vrr_1xI * vrr_1yR;
            gout31R += xyR * hrr_02zR - xyI * hrr_02zI;
            gout31I += xyR * hrr_02zI + xyI * hrr_02zR;
            double hrr_12zR = hrr_21zR - zjzi * hrr_11zR;
            double hrr_12zI = hrr_21zI - zjzi * hrr_11zI;
            xyR = vrr_1xR * 1;
            xyI = vrr_1xI * 1;
            gout32R += xyR * hrr_12zR - xyI * hrr_12zI;
            gout32I += xyR * hrr_12zI + xyI * hrr_12zR;
            xyR = fac * vrr_2yR;
            xyI = fac * vrr_2yI;
            gout33R += xyR * hrr_02zR - xyI * hrr_02zI;
            gout33I += xyR * hrr_02zI + xyI * hrr_02zR;
            xyR = fac * vrr_1yR;
            xyI = fac * vrr_1yI;
            gout34R += xyR * hrr_12zR - xyI * hrr_12zI;
            gout34I += xyR * hrr_12zI + xyI * hrr_12zR;
            double vrr_4zR = 3*a2 * vrr_2zR + zpaR * vrr_3zR - zpaI * vrr_3zI;
            double hrr_31zR = vrr_4zR - zjzi * vrr_3zR;
            double hrr_22zR = hrr_31zR - zjzi * hrr_21zR;
            double vrr_4zI = 3*a2 * vrr_2zI + zpaR * vrr_3zI + zpaI * vrr_3zR;
            double hrr_31zI = vrr_4zI - zjzi * vrr_3zI;
            double hrr_22zI = hrr_31zI - zjzi * hrr_21zI;
            xyR = fac * 1;
            gout35R += xyR * hrr_22zR;
            gout35I += xyR * hrr_22zI;
        }
    }
    if (Gv_block_id * nGv_per_block + Gv_id < nGv) {
        int *ao_loc = envs.ao_loc;
        int ncells = envs.bvk_ncells;
        int nbasp = nbas / ncells;
        size_t nao = ao_loc[nbasp];
        size_t cell_id = jsh / nbasp;
        int cell0_jsh = jsh % nbasp;
        size_t i0 = ao_loc[ish];
        size_t j0 = ao_loc[cell0_jsh];
        size_t addr;
        double *aft_tensor = out + 
                (cell_id * nao*nao*nGv + (i0*nao+j0) * nGv
                 + Gv_block_id*nGv_per_block + Gv_id) * OF_COMPLEX;
        addr = (0*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout0R;
        aft_tensor[addr*2+1] = gout0I;
        addr = (0*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout6R;
        aft_tensor[addr*2+1] = gout6I;
        addr = (0*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout12R;
        aft_tensor[addr*2+1] = gout12I;
        addr = (0*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout18R;
        aft_tensor[addr*2+1] = gout18I;
        addr = (0*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout24R;
        aft_tensor[addr*2+1] = gout24I;
        addr = (0*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout30R;
        aft_tensor[addr*2+1] = gout30I;
        addr = (1*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout1R;
        aft_tensor[addr*2+1] = gout1I;
        addr = (1*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout7R;
        aft_tensor[addr*2+1] = gout7I;
        addr = (1*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout13R;
        aft_tensor[addr*2+1] = gout13I;
        addr = (1*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout19R;
        aft_tensor[addr*2+1] = gout19I;
        addr = (1*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout25R;
        aft_tensor[addr*2+1] = gout25I;
        addr = (1*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout31R;
        aft_tensor[addr*2+1] = gout31I;
        addr = (2*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout2R;
        aft_tensor[addr*2+1] = gout2I;
        addr = (2*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout8R;
        aft_tensor[addr*2+1] = gout8I;
        addr = (2*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout14R;
        aft_tensor[addr*2+1] = gout14I;
        addr = (2*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout20R;
        aft_tensor[addr*2+1] = gout20I;
        addr = (2*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout26R;
        aft_tensor[addr*2+1] = gout26I;
        addr = (2*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout32R;
        aft_tensor[addr*2+1] = gout32I;
        addr = (3*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout3R;
        aft_tensor[addr*2+1] = gout3I;
        addr = (3*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout9R;
        aft_tensor[addr*2+1] = gout9I;
        addr = (3*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout15R;
        aft_tensor[addr*2+1] = gout15I;
        addr = (3*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout21R;
        aft_tensor[addr*2+1] = gout21I;
        addr = (3*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout27R;
        aft_tensor[addr*2+1] = gout27I;
        addr = (3*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout33R;
        aft_tensor[addr*2+1] = gout33I;
        addr = (4*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout4R;
        aft_tensor[addr*2+1] = gout4I;
        addr = (4*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout10R;
        aft_tensor[addr*2+1] = gout10I;
        addr = (4*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout16R;
        aft_tensor[addr*2+1] = gout16I;
        addr = (4*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout22R;
        aft_tensor[addr*2+1] = gout22I;
        addr = (4*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout28R;
        aft_tensor[addr*2+1] = gout28I;
        addr = (4*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout34R;
        aft_tensor[addr*2+1] = gout34I;
        addr = (5*nao+0)*nGv;
        aft_tensor[addr*2  ] = gout5R;
        aft_tensor[addr*2+1] = gout5I;
        addr = (5*nao+1)*nGv;
        aft_tensor[addr*2  ] = gout11R;
        aft_tensor[addr*2+1] = gout11I;
        addr = (5*nao+2)*nGv;
        aft_tensor[addr*2  ] = gout17R;
        aft_tensor[addr*2+1] = gout17I;
        addr = (5*nao+3)*nGv;
        aft_tensor[addr*2  ] = gout23R;
        aft_tensor[addr*2+1] = gout23I;
        addr = (5*nao+4)*nGv;
        aft_tensor[addr*2  ] = gout29R;
        aft_tensor[addr*2+1] = gout29I;
        addr = (5*nao+5)*nGv;
        aft_tensor[addr*2  ] = gout35R;
        aft_tensor[addr*2+1] = gout35I;
    }
}

int ft_ao_unrolled(double *out, AFTIntEnvVars *envs, AFTBoundsInfo *bounds, int *scheme)
{
    int li = bounds->li;
    int lj = bounds->lj;
    int nGv_per_block = scheme[0];
    int nsp_per_block = scheme[1] * scheme[2];
#if CUDA_VERSION >= 12040
    switch (li*5 + lj) {
    case 0: nsp_per_block *= 4; break;
    case 1: nsp_per_block *= 2; break;
    case 2: nsp_per_block *= 2; break;
    case 5: nsp_per_block *= 2; break;
    case 6: nsp_per_block *= 2; break;
    case 10: nsp_per_block *= 2; break;
    }
#endif
    int npairs_ij = bounds->npairs_ij;
    int ngrids = bounds->ngrids;
    int sp_blocks = (npairs_ij + nsp_per_block - 1) / nsp_per_block;
    int Gv_batches = (ngrids + nGv_per_block - 1) / nGv_per_block;
    dim3 threads(nGv_per_block, nsp_per_block);
    dim3 blocks(sp_blocks, Gv_batches);
    switch (li*5 + lj) {
    case 0: ft_ao_unrolled_00<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 1: ft_ao_unrolled_01<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 2: ft_ao_unrolled_02<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 5: ft_ao_unrolled_10<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 6: ft_ao_unrolled_11<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 7: ft_ao_unrolled_12<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 10: ft_ao_unrolled_20<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 11: ft_ao_unrolled_21<<<blocks, threads>>>(out, *envs, *bounds); break;
    case 12: ft_ao_unrolled_22<<<blocks, threads>>>(out, *envs, *bounds); break;
    default: return 0;
    }
    return 1;
}
