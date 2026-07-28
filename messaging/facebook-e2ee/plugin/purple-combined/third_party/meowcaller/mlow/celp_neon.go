//go:build arm && cgo

package mlow

// NEON bridge for the coarse CELP kernels (webOS TouchPad build). Pure-Go fallback in celp_fallback.go.

// #cgo CFLAGS: -O3 -mfpu=neon -ffast-math -g0
// void wa_celp_mult_symtoepl2(const float *c, int lResp, const float *x, float *y, int n);
// void wa_celp_filt_ma(const float *x, int xBase, int n, const float *coef, int coefLen, float *y);
import "C"

import "unsafe"

const celpNeonAvail = true

func neonMultSymtoepl2(c []float32, lResp int, x, y []float32, n int) {
	C.wa_celp_mult_symtoepl2((*C.float)(unsafe.Pointer(&c[0])), C.int(lResp),
		(*C.float)(unsafe.Pointer(&x[0])), (*C.float)(unsafe.Pointer(&y[0])), C.int(n))
}

func neonFiltMa(x []float32, xBase, n int, coef []float32, coefLen int, y []float32) {
	C.wa_celp_filt_ma((*C.float)(unsafe.Pointer(&x[0])), C.int(xBase), C.int(n),
		(*C.float)(unsafe.Pointer(&coef[0])), C.int(coefLen), (*C.float)(unsafe.Pointer(&y[0])))
}
