/**
 * Fresh algorithm
 */
extern "C" {
#include "sph/sph_shavite.h"
#include "sph/sph_simd.h"
#include "sph/sph_echo.h"
}
#include "miner.h"
#include "cuda_helper.h"

// to test gpu hash on a null buffer
#define NULLTEST 0

static uint32_t *d_hash[MAX_GPUS];
static uint32_t *h_found[MAX_GPUS];

extern void x11_shavite512_setBlock_80(int thr_id, void *pdata);
extern void x11_shavite512_cpu_hash_80(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash);
extern void x11_shavite512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash);

extern int  x11_simd512_cpu_init(int thr_id, uint32_t threads);
extern void x11_simd512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_hash, const uint32_t simdthreads);

extern void x11_echo512_cpu_init(int thr_id, uint32_t threads);
//extern void x11_echo512_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, uint32_t *d_nonceVector, uint32_t *d_hash);
extern void x11_echo512_cpu_hash_64_final(int thr_id, uint32_t threads, uint32_t startNounce, const uint32_t *d_hash, uint32_t target, uint32_t *h_found);

extern void quark_compactTest_cpu_init(int thr_id, uint32_t threads);
extern void quark_compactTest_cpu_hash_64(int thr_id, uint32_t threads, uint32_t startNounce, const uint32_t *inpHashes,
											const uint32_t *d_noncesTrue, uint32_t *nrmTrue, uint32_t *d_noncesFalse, uint32_t *nrmFalse);

// CPU Hash
extern "C" void fresh_hash(void *state, const void *input)
{
	// shavite-simd-shavite-simd-echo

	sph_shavite512_context ctx_shavite;
	sph_simd512_context ctx_simd;
	sph_echo512_context ctx_echo;

	unsigned char hash[128]; // uint32_t hashA[16], hashB[16];
	#define hashA hash
	#define hashB hash+64

	memset(hash, 0, sizeof hash);

	sph_shavite512_init(&ctx_shavite);
	sph_shavite512(&ctx_shavite, input, 80);
	sph_shavite512_close(&ctx_shavite, hashA);

	sph_simd512_init(&ctx_simd);
	sph_simd512(&ctx_simd, hashA, 64);
	sph_simd512_close(&ctx_simd, hashB);

	sph_shavite512_init(&ctx_shavite);
	sph_shavite512(&ctx_shavite, hashB, 64);
	sph_shavite512_close(&ctx_shavite, hashA);

	sph_simd512_init(&ctx_simd);
	sph_simd512(&ctx_simd, hashA, 64);
	sph_simd512_close(&ctx_simd, hashB);

	sph_echo512_init(&ctx_echo);
	sph_echo512(&ctx_echo, hashB, 64);
	sph_echo512_close(&ctx_echo, hashA);

	memcpy(state, hash, 32);
}

static volatile bool init[MAX_GPUS] = { false };

extern int scanhash_fresh(int thr_id, uint32_t *pdata,
	uint32_t *ptarget, uint32_t max_nonce,
	uint32_t *hashes_done)
{
	const uint32_t first_nonce = pdata[19];
	uint32_t endiandata[20];

	uint32_t throughput = device_intensity(device_map[thr_id], __func__, 1 << 19);
	throughput = min(throughput, (max_nonce - first_nonce)) & 0xfffffc00;
	uint32_t simdthreads = (device_sm[device_map[thr_id]] > 500) ? 256 : 32;

	if (opt_benchmark)
		ptarget[7] = 0xf;

	if (!init[thr_id])
	{
		CUDA_SAFE_CALL(cudaSetDevice(device_map[thr_id]));
		cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
		cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
		CUDA_SAFE_CALL(cudaStreamCreate(&gpustream[thr_id]));

		x11_simd512_cpu_init(thr_id, throughput);
		x11_echo512_cpu_init(thr_id, throughput);

		CUDA_SAFE_CALL(cudaMalloc(&d_hash[thr_id], 16 * sizeof(uint32_t) * throughput + 4));
		CUDA_SAFE_CALL(cudaMallocHost(&(h_found[thr_id]), 4 * sizeof(uint32_t)));

		cuda_check_cpu_init(thr_id, throughput);

		init[thr_id] = true;
	}

	for (int k=0; k < 20; k++)
		be32enc(&endiandata[k], pdata[k]);
	
	x11_shavite512_setBlock_80(thr_id, (void*)endiandata);

	do {

		// GPU Hash

		x11_shavite512_cpu_hash_80(thr_id, throughput, pdata[19], d_hash[thr_id]);
		x11_simd512_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id], simdthreads);
		x11_shavite512_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id]);
		x11_simd512_cpu_hash_64(thr_id, throughput, pdata[19], d_hash[thr_id], simdthreads);
		x11_echo512_cpu_hash_64_final(thr_id, throughput, pdata[19], d_hash[thr_id], ptarget[7], h_found[thr_id]);
		cudaStreamSynchronize(gpustream[thr_id]);

		if(stop_mining) {mining_has_stopped[thr_id] = true; cudaStreamDestroy(gpustream[thr_id]); pthread_exit(nullptr);}
		if(h_found[thr_id][0] != 0xffffffff)
		{
			const uint32_t Htarg = ptarget[7];
			uint32_t vhash64[8];
			be32enc(&endiandata[19], h_found[thr_id][0]);
			fresh_hash(vhash64, endiandata);

			if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
			{
				int res = 1;
				*hashes_done = pdata[19] - first_nonce + throughput;
				if (h_found[thr_id][1] != 0xffffffff)
				{
					be32enc(&endiandata[19], h_found[thr_id][1]);
					fresh_hash(vhash64, endiandata);
					if (vhash64[7] <= Htarg && fulltest(vhash64, ptarget))
					{

						pdata[21] = h_found[thr_id][1];
						res++;
						if (opt_benchmark)
							applog(LOG_INFO, "GPU #%d Found second nounce %08x", device_map[thr_id], h_found[thr_id][1]);
					}
					else
					{
						if (vhash64[7] != Htarg)
						{
							applog(LOG_WARNING, "GPU #%d: result for %08x does not validate on CPU!", device_map[thr_id], h_found[thr_id][1]);
						}
					}

				}
				pdata[19] = h_found[thr_id][0];
				if (opt_benchmark)
					applog(LOG_INFO, "GPU #%d Found nounce %08x", device_map[thr_id], h_found[thr_id][0]);
				return res;
			}
			else
			{
				if (vhash64[7] != Htarg)
				{
					applog(LOG_WARNING, "GPU #%d: result for %08x does not validate on CPU!", device_map[thr_id], h_found[thr_id][0]);
				}
			}
		}
		pdata[19] += throughput; CUDA_SAFE_CALL(cudaGetLastError());
	} while (!work_restart[thr_id].restart && ((uint64_t)max_nonce > ((uint64_t)(pdata[19]) + (uint64_t)throughput)));

	*hashes_done = pdata[19] - first_nonce + 1;
	return 0;
}
