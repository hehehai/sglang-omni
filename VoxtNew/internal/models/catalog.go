// Package models is VoxtNew's model catalogue, and the models on disk:
// the few curated models (each pinned to a Hugging Face revision, with
// every file's size and SHA-256), where they live in the data folder,
// which are installed, and their downloads (resumable, verified, moved
// into place at once, cancellable), or their adoption from a Hugging Face
// cache already on the Mac (a developer's option).
//
// The catalogue's ids are stable: settings keep them. What a model is
// called and what it is good at is the UI's (internal/uitext); repos,
// revisions and quantisations stay here.
//
// Imports: nothing internal.
package models

// Kind is what a model does.
type Kind string

const (
	ASR Kind = "asr" // speech recognition
	LLM Kind = "llm" // a language model
	VAD Kind = "vad" // voice activity detection: a helper model, not chosen by the user
)

// Runtime is what runs a model.
type Runtime string

const (
	Omni Runtime = "omni" // sglang_omni_mlx/native's servers
	MLX  Runtime = "mlx"  // voxtnew-llm, mlx-swift-lm
	GGUF Runtime = "gguf" // voxtnew-llm, llama.cpp
)

// The catalogue's ids.
const (
	ASRAccurate  = "asr.accurate"
	ASRFast      = "asr.fast"
	VADSilero    = "vad.silero"
	LLMBalanced  = "llm.balanced"
	LLMFast      = "llm.fast"
	LLMTranslate = "llm.translate"
)

// File is one file of a model, at its path in the repo (and in the
// model's folder).
type File struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Model is one model of the catalogue.
type Model struct {
	ID      string
	Kind    Kind
	Runtime Runtime
	// Repo and Revision are the Hugging Face repo and the commit pinned.
	Repo, Revision string
	Files          []File
	// Default: the recommended model of its kind.
	Default bool
	// Features are the only features it serves ("translate"), nil for
	// every one.
	Features []string
	// Needs are models installed with it (a speech model: the VAD).
	Needs []string
}

// Size is the size of the model's files.
func (m Model) Size() int64 {
	var n int64
	for _, f := range m.Files {
		n += f.Size
	}
	return n
}

// Catalog is every model, the recommended first of each kind.
func Catalog() []Model {
	out := make([]Model, len(catalog))
	copy(out, catalog)
	return out
}

// Lookup is the model of id.
func Lookup(id string) (Model, bool) {
	for _, m := range catalog {
		if m.ID == id {
			return m, true
		}
	}
	return Model{}, false
}

// The omni models' pins are sglang_omni_mlx/native/ci/models.json's
// (TestOmniPins); the language models' were read from the Hub, with the
// files Voxt's loaders take (weights, configs, tokenizer, chat template).
var catalog = []Model{
	{
		ID: ASRAccurate, Kind: ASR, Runtime: Omni, Default: true, Needs: []string{VADSilero},
		Repo: "mlx-community/Qwen3-ASR-1.7B-8bit", Revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
		Files: []File{
			{"chat_template.json", 1161, "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"},
			{"config.json", 7188, "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"},
			{"generation_config.json", 142, "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"},
			{"merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"},
			{"model.safetensors", 2463307541, "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"},
			{"model.safetensors.index.json", 78968, "0a5d0ec11188602242ff81a9969883d0fdeb98cd5d85cd1413089d897c201af5"},
			{"preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"},
			{"tokenizer_config.json", 12487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"},
			{"vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"},
		},
	},
	{
		ID: ASRFast, Kind: ASR, Runtime: Omni, Needs: []string{VADSilero},
		Repo: "mlx-community/Qwen3-ASR-0.6B-4bit", Revision: "313d850181767edf09f00a9c289becca70e58cd0",
		Files: []File{
			{"chat_template.json", 1161, "75a8cfca24f00de72d796fbfed6858fc9614ef3dabd8696684cc3bc03a9c58ff"},
			{"config.json", 7187, "923618cf5ca452fda0253a6be5c1a17f94a2e4851d3b98beb45848565587bd72"},
			{"generation_config.json", 142, "1da527824d81e07118facff437e03f2e24a23311e3bdeb2368973fe77e5f275c"},
			{"merges.txt", 1671853, "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"},
			{"model.safetensors", 708236945, "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"},
			{"model.safetensors.index.json", 71814, "e3bb80ef0fd42a5be07b04e90c97d60460bbde8af3531e0bfe9100a61404d81a"},
			{"preprocessor_config.json", 330, "45e120a4eda2c20c5d7f2ea9354e63536bf35e27aa573fb7cdf78017b378770d"},
			{"tokenizer_config.json", 12487, "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"},
			{"vocab.json", 2776833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"},
		},
	},
	{
		ID: VADSilero, Kind: VAD, Runtime: Omni, Default: true,
		Repo: "mlx-community/silero-vad-v6", Revision: "2ebf4a5e10726a2e78ddd4d70eedfb6f1c33eb06",
		Files: []File{
			{"config.json", 463, "9fe1befb9692a0d4135adadc33f8075ef6d350bd2391b88d750f2c233f97fa0b"},
			{"model.safetensors", 1237860, "65b6c5f0293cbc44d109e58bef78b474d9c65dedbee814cf0b90ef5f0d9150ff"},
		},
	},
	{
		ID: LLMBalanced, Kind: LLM, Runtime: MLX, Default: true,
		Repo: "mlx-community/Qwen3.5-4B-OptiQ-4bit", Revision: "6cb5bdfd0bf15f484881fb9f1ab6d7c840fddde9",
		Files: []File{
			{"chat_template.jinja", 7756, "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"},
			{"config.json", 55543, "aa725a49a83c5503506ff7dcbc57efdaeb7e64a5fa6e4b547d49979a29aec1b3"},
			{"generation_config.json", 148, "f2130efdf66df1834aa4f7a6e48752e88a8dff41965739c6ffb2bb26c841615e"},
			{"kv_config.json", 528, "5de3659fa5db489d9ae8ef95eee8963ae6c778099a4de06de7994cce61d82129"},
			{"model.safetensors", 3269669552, "5d59fea455202270c0f7f71a1902516b06457df5600c3182e1ff9163c33287c1"},
			{"model.safetensors.index.json", 100945, "67306a1f0b0181d92adfe92fce654b6c91ee0c5c2b51b0de114ced2a2ecdbcbc"},
			{"optiq/mtp.safetensors", 86701044, "a5b658f4145445564c3f7990fd7c3b551b8a2de990c0a743ddde05736e8ded30"},
			{"optiq/optiq_vision.safetensors", 667061501, "2f3a952d401ef2e5735c0b56a0b718e338224a0d7af717f80a9315c26bdd8577"},
			{"optiq_metadata.json", 26224, "38eb38a541e2b169c258630fd4a64b2bf256a024abfc55ff0935f0ec495d4be2"},
			{"tokenizer.json", 19989343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"},
			{"tokenizer_config.json", 1135, "b2bed5e033438f09f22b0ce9522115b4807d9bbcc3b82bf23372cb74d93ed081"},
		},
	},
	{
		ID: LLMFast, Kind: LLM, Runtime: MLX,
		Repo: "mlx-community/Qwen3.5-2B-4bit", Revision: "674aaa7240b91e8012fcad5d791b7dfe5ba90207",
		Files: []File{
			{"chat_template.jinja", 7755, "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80"},
			{"config.json", 3113, "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949"},
			{"model.safetensors", 1722271785, "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5"},
			{"model.safetensors.index.json", 81722, "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d"},
			{"preprocessor_config.json", 390, "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516"},
			{"processor_config.json", 1300, "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b"},
			{"tokenizer.json", 19989343, "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"},
			{"tokenizer_config.json", 1139, "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"},
			{"video_preprocessor_config.json", 385, "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13"},
			{"vocab.json", 6722759, "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003"},
		},
	},
	{
		ID: LLMTranslate, Kind: LLM, Runtime: GGUF, Features: []string{"translate"},
		Repo: "tencent/Hy-MT2-1.8B-GGUF", Revision: "a0c709d9fac510f2c807aa3af52872340dc37a4a",
		Files: []File{
			{"Hy-MT2-1.8B-Q4_K_M.gguf", 1133080448, "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"},
		},
	},
}
