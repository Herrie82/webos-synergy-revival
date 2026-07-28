// NEON-accelerated coarse CELP DSP kernels (webOS device build). These are the self-contained
// dot-product / FIR loops the encoder runs many times per frame; compiled with -mfpu=neon
// -ftree-vectorize -ffast-math the inner contiguous loops auto-vectorize. Only the COARSE functions
// live here (one cgo call does ~80+ dot products or a whole FIR pass) so the cgo call overhead is
// negligible; the tiny leaf dot-products stay in Go. Ports of the same-named Go functions; NOT
// bit-identical (-ffast-math reorders the accumulation), validated by PESQ.

// celpMultSymtoepl2: symmetric-Toeplitz matrix x vector (smpl_celp.rs). Three runs of a sliding
// dot-product with varying length/offset, exactly mirroring the Go.
void wa_celp_mult_symtoepl2(const float *c, int lResp, const float *x, float *y, int n) {
	int length = lResp;
	int nn = 0;
	for (; nn < lResp - 1; nn++) {
		const float *a = c + (lResp - 1 - nn);
		float r = 0.0f;
		for (int i = 0; i < length; i++) r += a[i] * x[i];
		y[nn] = r;
		length++;
	}
	length = 2 * lResp;
	for (; nn < n - lResp; nn++) {
		const float *b = x + (nn + 1 - lResp);
		float r = 0.0f;
		for (int i = 0; i < length; i++) r += c[i] * b[i];
		y[nn] = r;
	}
	for (; nn < n; nn++) {
		length--;
		const float *b = x + (nn + 1 - lResp);
		float r = 0.0f;
		for (int i = 0; i < length; i++) r += c[i] * b[i];
		y[nn] = r;
	}
}

// celpFiltMa: FIR (moving-average) filter y[k] = sum_i coef[i]*x[xBase+k-i]. The per-tap inner loops
// over k are contiguous and vectorize.
void wa_celp_filt_ma(const float *x, int xBase, int n, const float *coef, int coefLen, float *y) {
	int i;
	if (coef[0] == 1.0f) {
		for (int k = 0; k < n; k++) y[k] = x[xBase + k] + coef[1] * x[xBase + k - 1];
		i = 2;
	} else {
		for (int k = 0; k < n; k++) y[k] = coef[0] * x[xBase + k];
		i = 1;
	}
	for (; i < coefLen; i++) {
		float ci = coef[i];
		for (int k = 0; k < n; k++) y[k] += ci * x[xBase + k - i];
	}
}
