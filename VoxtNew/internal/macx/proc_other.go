//go:build !darwin

package macx

func procMemory(int) (ProcMemory, error) { return ProcMemory{}, ErrUnsupported }
