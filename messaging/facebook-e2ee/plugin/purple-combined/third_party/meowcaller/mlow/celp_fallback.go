//go:build !(arm && cgo)

package mlow

// Non-ARM / no-cgo builds keep the pure-Go CELP kernels.
const celpNeonAvail = false

func neonMultSymtoepl2(c []float32, lResp int, x, y []float32, n int) {}
func neonFiltMa(x []float32, xBase, n int, coef []float32, coefLen int, y []float32) {}
