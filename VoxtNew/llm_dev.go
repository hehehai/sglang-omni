package main

// The language models' developer hook (internal/llmrt, dev.go):
// VOXTNEW_DEV_LLM=<id>=<dir>[,<id>=<dir>…] lists those curated models as
// installed, run by voxtnew-llm, until the catalogue (M1b) installs them
// for real. Without it nothing changes.
//
//	VOXTNEW_DEV_LLM=llm.balanced=~/models/qwen open build/darwin-arm64/VoxtNew.app

import (
	"log"
	"os"

	"github.com/egoist/mygo"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/core"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/llmrt"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/local"
)

// withDevLLM is base with the hook's models, and the runtime that runs
// them (a.llmrt), when VOXTNEW_DEV_LLM is set.
func (a *app) withDevLLM(base local.Services) local.Services {
	spec := os.Getenv(llmrt.DevEnv)
	if spec == "" {
		return base
	}
	models, err := llmrt.ParseDev(spec)
	if err != nil {
		log.Printf("%v", err)
		return base
	}
	resources, _ := mygo.App.Path(mygo.PathResources)
	logDir, _ := mygo.App.Path(mygo.PathLogs)
	a.llmrt = llmrt.New(llmrt.Config{
		Bin: llmrt.Find(resources), AppVersion: mygo.App.Version(), LogDir: logDir,
		Log: func(e core.LogEntry) {
			if l := a.logs; l != nil {
				l.Append(e)
			}
		},
	})
	return llmrt.DevServices(base, a.llmrt, models)
}

// stopLLM stops the language models' process (the app quits).
func (a *app) stopLLM() {
	if a.llmrt != nil {
		a.llmrt.Stop()
	}
}
