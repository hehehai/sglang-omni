//go:build demo

package main

// The demo build's sample data (demo.go): the history, the dictionary and
// the app enhancement groups it seeds, in English and in Chinese.

import (
	"context"
	"fmt"
	"log"
	"os"
	"time"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/appctx"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/core"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/settings"
	"github.com/sgl-project/sglang-omni/VoxtNew/internal/store"
)

// ---- sample data ----

// demoSeed fills an empty library with the sample data of
// $VOXTNEW_DEMO_LANG (en, zh).
func demoSeed(lib *library) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if list, err := lib.store.History().List(ctx, store.HistoryQuery{Limit: 1}); err != nil || len(list) > 0 {
		return
	}
	zh := os.Getenv("VOXTNEW_DEMO_LANG") == "zh"
	d := demoDataEN
	if zh {
		d = demoDataZH
	}
	err := lib.settings.Update(ctx, func(s *settings.Settings) {
		s.General.Language, s.General.MainLanguage, s.General.OtherLanguages = "en", "en", []string{"zh"}
		s.Features.Translate.Target = "en"
		if zh {
			s.General.Language, s.General.MainLanguage, s.General.OtherLanguages = "zh-Hans", "zh", []string{"en"}
			s.Features.Translate.Target = "zh"
		}
		s.Appearance.Theme = "light"
		s.Audio.Sounds = false
		s.Features.Translate.ShowCard = true
		s.Providers.ASR = []settings.Provider{{ID: "stepfun", Enabled: true}}
		s.Providers.LLM = []settings.Provider{{ID: "deepseek", Enabled: true}}
		s.Setup.Done, s.Setup.Tried = true, true
	})
	if err != nil {
		log.Printf("demo: settings: %v", err)
	}
	var rules appctx.Rules
	for i, g := range d.groups {
		rules.Groups = append(rules.Groups, appctx.Group{ID: fmt.Sprintf("demo-%d", i+1), Name: g.name, Enabled: true, Prompt: g.prompt,
			Apps: g.apps, URLs: g.urls, AutoKey: g.autoKey, Features: g.features})
	}
	if b, err := rules.Marshal(); err == nil {
		lib.store.Documents().Put(ctx, appctx.Key, b)
	}
	now := time.Now()
	for i, t := range d.terms {
		at := now.Add(-time.Duration(len(d.terms)-i) * 26 * time.Hour)
		lib.store.Dictionary().Put(ctx, store.Term{ID: core.NewID(at), Term: t.term, Aliases: t.aliases, Note: t.note, Enabled: true, CreatedAt: at, UpdatedAt: at})
	}
	for _, e := range d.history {
		at := now.Add(-e.ago)
		ent := store.Entry{ID: core.NewID(at), Kind: e.kind, CreatedAt: at, Status: store.StatusDone,
			AppBundle: e.app.BundleID, AppName: e.app.Name, URLHost: e.host,
			RawText: e.raw, SourceText: e.source, PromptText: e.prompt, Result: e.result, TargetLang: e.target,
			Delivery: "insert", ASRProvider: "stepfun", ASRModel: "step-asr", LLMProvider: "deepseek", LLMModel: "deepseek-flash",
			AudioMS: e.audioMS, SentMS: e.audioMS * 85 / 100, ASRMS: 600 + e.audioMS/12, LLMMS: 700 + int64(len(e.result))*3, DSP: "highpass+level", GainDB: 4.5}
		ent.TotalMS = ent.AudioMS + ent.ASRMS + ent.LLMMS + 180
		if e.group > 0 {
			g := rules.Groups[e.group-1]
			ent.RuleID, ent.RuleName, ent.RuleSource = g.ID, g.Name, string(appctx.SourceApp)
			if e.host != "" {
				ent.RuleSource = string(appctx.SourceURL)
			}
		}
		if e.kind == store.KindTranslate && e.source != "" || e.kind == store.KindRewrite && e.prompt == "" {
			ent.ASRProvider, ent.ASRModel, ent.AudioMS, ent.SentMS, ent.ASRMS, ent.DSP, ent.GainDB = "", "", 0, 0, 0, "", 0
			ent.TotalMS = ent.LLMMS + 150
		}
		if e.card {
			ent.Delivery = "card"
		}
		if err := lib.store.History().Put(ctx, ent); err != nil {
			log.Printf("demo: history: %v", err)
		}
	}
}

type demoGroup struct {
	name, prompt string
	apps         []appctx.App
	urls         []string
	autoKey      string
	features     appctx.Features
}

type demoTerm struct {
	term    string
	aliases []string
	note    string
}

type demoEntry struct {
	ago                                 time.Duration
	kind                                store.Kind
	app                                 proto.App
	host                                string
	group                               int // 1-based; 0 none
	raw, source, prompt, result, target string
	audioMS                             int64
	card                                bool
}

type demoData struct {
	groups  []demoGroup
	terms   []demoTerm
	history []demoEntry
}

var (
	appDiscord  = proto.App{BundleID: "com.hnc.Discord", Name: "Discord"}
	appTelegram = proto.App{BundleID: "ru.keepcoder.Telegram", Name: "Telegram"}
	appLark     = proto.App{BundleID: "com.electron.lark", Name: "Lark"}
	appWeChat   = proto.App{BundleID: "com.tencent.xinWeChat", Name: "WeChat"}
	appMail     = proto.App{BundleID: "com.apple.mail", Name: "Mail"}
	appCursor   = proto.App{BundleID: "com.todesktop.230313mzl4w4u92", Name: "Cursor"}
	appZed      = proto.App{BundleID: "dev.zed.Zed", Name: "Zed"}
	appXcode    = proto.App{BundleID: "com.apple.dt.Xcode", Name: "Xcode"}
	appTextEdit = proto.App{BundleID: "com.apple.TextEdit", Name: "TextEdit"}
	appObsidian = proto.App{BundleID: "md.obsidian", Name: "Obsidian"}
	appNotes    = proto.App{BundleID: "com.apple.Notes", Name: "Notes"}
	appChrome   = proto.App{BundleID: "com.google.Chrome", Name: "Google Chrome"}
	appSafari   = proto.App{BundleID: "com.apple.Safari", Name: "Safari"}
	appFigma    = proto.App{BundleID: "com.figma.Desktop", Name: "Figma"}
)

func asApps(as ...proto.App) []appctx.App {
	out := make([]appctx.App, len(as))
	for i, a := range as {
		out[i] = appctx.App{BundleID: a.BundleID, Name: a.Name}
	}
	return out
}

const (
	min_ = time.Minute
	hr   = time.Hour
	day  = 24 * time.Hour
)

var demoDataEN = demoData{
	groups: []demoGroup{
		{name: "Team chat", prompt: "A team chat: short and casual, no greeting or sign-off, one message per thought.",
			apps: asApps(appDiscord, appTelegram, appLark), urls: []string{"app.slack.com"}, autoKey: "Return",
			features: appctx.Features{Transcribe: true, Rewrite: true}},
		{name: "Email", prompt: "An email: complete sentences in a friendly, professional tone. Keep names, dates and times exactly as said.",
			apps: asApps(appMail), urls: []string{"mail.google.com", "outlook.office.com"},
			features: appctx.Features{Transcribe: true, Translate: true, Rewrite: true}},
		{name: "Code & docs", prompt: "Technical writing: keep code identifiers, file names, commands and flags exactly as spoken, in backticks.",
			apps: asApps(appCursor, appZed, appXcode), urls: []string{"github.com", "*.notion.so/*"},
			features: appctx.Features{Transcribe: true, Rewrite: true}},
		{name: "Notes", prompt: "Notes and documents: clear punctuation, a new paragraph for each separate point.",
			apps:     asApps(appTextEdit, appObsidian, appNotes),
			features: appctx.Features{Transcribe: true, Rewrite: true}},
	},
	terms: []demoTerm{
		{"VoxtNew", []string{"aura link", "aural link"}, "The app's name"},
		{"StepFun", []string{"step fun"}, ""},
		{"DeepSeek", []string{"deep seek"}, ""},
		{"Kubernetes", []string{"cooper netties", "kuber nets"}, ""},
		{"Figma", []string{"figma's", "fig ma"}, ""},
		{"OKRs", []string{"okay ours", "o k r s"}, "Objectives and key results"},
		{"Priya", []string{"pria", "prea"}, "Design lead"},
		{"Joaquín", []string{"wakeen", "joaquin"}, "Backend, Madrid office"},
	},
	history: []demoEntry{
		{ago: 12 * min_, kind: store.KindTranscribe, app: appDiscord, group: 1,
			raw:    "um pushed the fix for the login timeout uh can someone check it on staging",
			result: "Pushed the fix for the login timeout, can someone check it on staging?", audioMS: 5200},
		{ago: 38 * min_, kind: store.KindRewrite, app: appMail, group: 2,
			source: "cant make it thurs, can we move the sync? sorry", prompt: "make it polite and suggest friday morning",
			result: "Sorry, I can't make Thursday. Could we move our sync to Friday morning?", audioMS: 3100},
		{ago: 55 * min_, kind: store.KindTranscribe, app: appCursor, group: 3,
			raw:    "rename load history to open history and keep the old name as an alias until the next release",
			result: "Rename `loadHistory` to `openHistory` and keep the old name as an alias until the next release.", audioMS: 6400},
		{ago: 1*hr + 20*min_, kind: store.KindTranslate, app: appChrome, host: "github.com", group: 0,
			source: "这个版本先灰度百分之十，周五再全量发布。",
			result: "We'll roll this version out to 10% first, then to everyone on Friday.", target: "en", card: true},
		{ago: 2 * hr, kind: store.KindTranscribe, app: appObsidian, group: 4,
			raw:    "ideas for onboarding show one real try of each feature then hide the checklist once everything is ready",
			result: "Ideas for onboarding: show one real try of each feature, then hide the checklist once everything is ready.", audioMS: 7300},
		{ago: 3*hr + 10*min_, kind: store.KindTranscribe, app: appTelegram, group: 1,
			raw:    "running five minutes late start without me",
			result: "Running five minutes late, start without me.", audioMS: 2400},
		{ago: 4 * hr, kind: store.KindTranslate, app: appFigma, group: 0,
			raw: "保存草稿", result: "Save draft", target: "en", audioMS: 1500},
		{ago: 5*hr + 30*min_, kind: store.KindRewrite, app: appNotes, group: 4,
			prompt: "write a short agenda for tomorrow's design review",
			result: "Design review agenda\n\n1. Onboarding flow: open questions\n2. History page: filters and search\n3. Next steps and owners", audioMS: 3600, card: true},
		{ago: 1*day + 2*hr, kind: store.KindTranscribe, app: appMail, group: 2,
			raw:    "hi priya thanks for the review i've updated the figma file with the new spacing",
			result: "Hi Priya, thanks for the review. I've updated the Figma file with the new spacing.", audioMS: 5600},
		{ago: 1*day + 5*hr, kind: store.KindTranscribe, app: appZed, group: 3,
			raw:    "the kubernetes job fails because the config map is missing the region",
			result: "The Kubernetes job fails because the ConfigMap is missing the region.", audioMS: 4800},
	},
}

var demoDataZH = demoData{
	groups: []demoGroup{
		{name: "团队聊天", prompt: "团队聊天：简短口语化，不要称呼和落款，一个想法一条消息。",
			apps: asApps(appWeChat, appLark, appTelegram), autoKey: "Return",
			features: appctx.Features{Transcribe: true, Rewrite: true}},
		{name: "邮件", prompt: "邮件：完整的句子，礼貌、专业；人名、日期和时间按原话保留。",
			apps: asApps(appMail), urls: []string{"mail.google.com", "exmail.qq.com"},
			features: appctx.Features{Transcribe: true, Translate: true, Rewrite: true}},
		{name: "代码与文档", prompt: "技术写作：代码标识符、文件名、命令和参数按原样保留，用反引号括起来。",
			apps: asApps(appCursor, appZed, appXcode), urls: []string{"github.com", "*.feishu.cn/docx/*"},
			features: appctx.Features{Transcribe: true, Rewrite: true}},
		{name: "笔记", prompt: "笔记和文档：标点清楚，不同的要点分段。",
			apps:     asApps(appTextEdit, appObsidian, appNotes),
			features: appctx.Features{Transcribe: true, Rewrite: true}},
	},
	terms: []demoTerm{
		{"VoxtNew", []string{"奥拉林克", "aura link"}, "产品名"},
		{"阶跃星辰", []string{"接跃星辰", "阶跃新城"}, ""},
		{"DeepSeek", []string{"迪普西克", "deep seek"}, ""},
		{"飞书", []string{"飞叔", "非书"}, ""},
		{"灰度发布", []string{"灰度", "回度发布"}, ""},
		{"Kubernetes", []string{"酷伯内特斯", "k8s"}, ""},
		{"OKR", []string{"欧凯阿", "o k r"}, "目标与关键结果"},
		{"王芃", []string{"王鹏", "王朋"}, "设计负责人"},
	},
	history: []demoEntry{
		{ago: 12 * min_, kind: store.KindTranscribe, app: appWeChat, group: 1,
			raw:    "嗯登录超时那个问题我已经修了那个谁帮忙在测试环境看一下",
			result: "登录超时的问题我已经修了，谁帮忙在测试环境看一下？", audioMS: 4800},
		{ago: 38 * min_, kind: store.KindRewrite, app: appMail, group: 2,
			source: "周四去不了，同步会能不能挪一下，不好意思", prompt: "改得礼貌一点，建议改到周五上午",
			result: "不好意思，周四我去不了。我们的同步会能否改到周五上午？", audioMS: 3000},
		{ago: 55 * min_, kind: store.KindTranscribe, app: appCursor, group: 3,
			raw:    "把 load history 改名成 open history 旧名字先留一个别名到下个版本",
			result: "把 `loadHistory` 改名为 `openHistory`，旧名字先保留为别名，到下个版本再删。", audioMS: 6100},
		{ago: 1*hr + 20*min_, kind: store.KindTranslate, app: appChrome, host: "github.com", group: 0,
			source: "We'll roll this version out to 10% first, then to everyone on Friday.",
			result: "这个版本先灰度 10%，周五再全量发布。", target: "zh", card: true},
		{ago: 2 * hr, kind: store.KindTranscribe, app: appObsidian, group: 4,
			raw:    "引导页的想法每个功能让用户真的试一次然后全部就绪以后就把清单藏起来",
			result: "引导页的想法：每个功能让用户真实地试一次，全部就绪以后就把清单藏起来。", audioMS: 6900},
		{ago: 3*hr + 10*min_, kind: store.KindTranscribe, app: appLark, group: 1,
			raw:    "我晚五分钟你们先开始",
			result: "我晚到五分钟，你们先开始。", audioMS: 2200},
		{ago: 4 * hr, kind: store.KindTranslate, app: appFigma, group: 0,
			raw: "save draft", result: "保存草稿", target: "zh", audioMS: 1400},
		{ago: 5*hr + 30*min_, kind: store.KindRewrite, app: appNotes, group: 4,
			prompt: "写一个明天设计评审的简短议程",
			result: "设计评审议程\n\n1. 引导流程：待定问题\n2. 历史页：筛选与搜索\n3. 下一步与负责人", audioMS: 3300, card: true},
		{ago: 1*day + 2*hr, kind: store.KindTranscribe, app: appMail, group: 2,
			raw:    "王芃你好谢谢你的评审我已经按新的间距更新了 figma 文件",
			result: "王芃你好，谢谢你的评审。我已经按新的间距更新了 Figma 文件。", audioMS: 5300},
		{ago: 1*day + 5*hr, kind: store.KindTranscribe, app: appZed, group: 3,
			raw:    "kubernetes 的任务失败了因为 config map 里少了 region",
			result: "Kubernetes 的任务失败了，因为 ConfigMap 里少了 `region`。", audioMS: 4600},
	},
}
