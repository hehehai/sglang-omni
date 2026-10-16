# The README's media

The screenshots, the hero and the animations in the README are captured on a real Mac from a **demo build** of VoxtNew, then put together on Linux. Nothing in them is mocked: the overlay, the cards and the text in TextEdit are what the app did, with real StepFun and DeepSeek calls (recorded, and played back on retakes).

## The demo build

`demo.go` and `demo_data.go` (built only with `-tags demo`), `internal/demo` (the recorded and replayed service traffic, the keys) and the hooks in `demo_hooks.go` (nil in every other build). The demo app:

- is its own app: bundle ID `dev.hehehai.voxtnew.demo`, built in its own mirror (`MAC_DIR=code/VoxtNew-demo`), refusing to run as `dev.hehehai.voxtnew`;
- keeps its data, logs and cache in `$VOXTNEW_DEMO_DIR` (and runs with `HOME` there), and its keys in a file (`$VOXTNEW_DEMO_KEYS`: `STEPFUN_API_KEY`, `DEEPSEEK_API_KEY`), never the Keychain; Model services shows no part of them;
- seeds sample data on its first start (`$VOXTNEW_DEMO_LANG`, `en` or `zh`): settings, app enhancement groups, a dictionary and a history;
- registers no global shortcut (an installed VoxtNew keeps `fn`) and is driven by command files (`demo.sh ctl`): the shortcuts' events, pages, the card's language and Insert;
- starts sessions only while TextEdit is in front (`VOXTNEW_DEMO_TARGETS`);
- records the helper's input from a file (`VOXTNEW_HELPER_CAPTURE_FILE`: speech made with `say`), so it needs no microphone;
- records each take's HTTP exchanges and plays them back when the take runs again (`calls.log` counts the real calls).

It runs from the ssh shell rather than through Launch Services, so it uses that shell's Accessibility grant.

## Steps

```sh
MAC_DIR=code/VoxtNew-demo scripts/mac.sh scripts/readme-media/build.sh   # the demo app and alcap
# on the Mac, in ~/code/VoxtNew-demo (RUN=~/voxtnew-demo-run: keys.env, speech/, docs/, wall.png):
scripts/readme-media/demo.sh start en
scripts/readme-media/shots.sh en                      # the main window's pages
scripts/readme-media/take.sh en transcribe en-transcribe   # and translate, rewrite, hero
build/alcap menuextra "$(scripts/readme-media/demo.sh pid en)" "$RUN/shots/en/menu.png"
scripts/readme-media/demo.sh stop en
# on Linux:
rsync -a mac-air:voxtnew-demo-run/{shots,takes} /tmp/almedia/
SRC=/tmp/almedia scripts/readme-media/post.sh         # docs/images, docs/media
```

`take.sh` waits until the Mac's user has been idle for a minute and no other screen capture runs, puts TextEdit in front with a document, captures only TextEdit's and the demo's windows over a backdrop (`alcap`, ScreenCaptureKit), and gives the app in front back. The backdrop is `wallpaper.sh`'s gradient.
