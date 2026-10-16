package main

// The runtimes behind the local models (internal/local's Openers): the
// one place that says which runtime opens which model. A runtime that is
// not wired here is "not available" (local.ErrNoRuntime): M1 fills ASR
// (internal/omni: the speech model's folder, and the VAD's from
// a.models.Dir(models.VADSilero)), M2 fills LLM (the voxtnew-llm
// process).
//
// Developers' options, from the environment:
//
//	VOXTNEW_HF_ENDPOINT=<url>   download from this Hub instead of https://huggingface.co
//	VOXTNEW_HF_CACHE=1|<dir>    adopt verified files from a Hugging Face cache
//	                            (1: $HF_HUB_CACHE, $HF_HOME/hub or ~/.cache/huggingface/hub)
//	                            instead of downloading them

import (
	"log"
	"os"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/local"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/macx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/models"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/uitext"
)

// newLocalServices is the local models a new app uses (tests swap in
// fakes).
var newLocalServices = func(a *app) local.Services {
	return local.NewLibrary(a.models, a.localOpeners(), uitext.ModelName)
}

// localOpeners are the runtimes this build has.
func (a *app) localOpeners() local.Openers {
	return local.Openers{
		ASR:    a.openOmniASR, // models_omni.go
		LLM:    a.openLLM,     // llm_link.go
		Unload: a.unloadModel,
	}
}

// unloadModel is Openers.Unload: the runtime of model id's kind lets it
// go.
func (a *app) unloadModel(id string) {
	if m, ok := models.Lookup(id); ok && m.Kind == models.LLM {
		a.unloadLLM(id) // llm_link.go
		return
	}
	a.unloadOmni(id) // models_omni.go
}

// systemProxies are the Mac's web proxies, for the downloads.
func systemProxies() models.SystemProxies { return models.SystemProxies(macx.SystemProxies()) }

// managerOptions are the models' options: the environment's, the
// system's proxy, and onChange.
func managerOptions(onChange func()) models.Options {
	opt := models.Options{Endpoint: os.Getenv("VOXTNEW_HF_ENDPOINT"), OnChange: onChange,
		Proxy:    models.SystemProxy(systemProxies, log.Printf),
		DiskFree: func(path string) int64 { return diskFree(path) }} // settings_storage.go: snapshots and tests pin it
	switch cache := os.Getenv("VOXTNEW_HF_CACHE"); cache {
	case "", "0":
	case "1":
		opt.HFCache = models.DefaultHFCache()
	default:
		opt.HFCache = cache
	}
	return opt
}
