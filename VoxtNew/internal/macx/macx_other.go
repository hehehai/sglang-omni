//go:build !darwin

package macx

import "time"

func activate(int, time.Duration, func(func())) (bool, time.Duration) { return false, 0 }

func frontmost() App { return App{} }

func play(Sound) error { return nil }

func systemProxies() Proxies { return Proxies{} }

func windowNumber(uintptr) int { return 0 }
