#!/usr/bin/env bash
# apply-zh-hans.sh
#
# 一键为 Compositor 项目添加简体中文(简体)界面汉化,自动推送到 GitHub
# 并触发 Build x86_64 工作流。
#
# 用法:
#   GH_TOKEN=<ghp_xxx> ./apply-zh-hans.sh
#
# 可选环境变量:
#   REPO=<owner/repo>    默认 veelove/Compositor
#   BRANCH=<branch>      默认 main
#   SKIP_PUSH=1          不推送(本地审查后手动推)
#   SKIP_TRIGGER=1       不触发 Build 工作流
#   RESTORE=1            移除汉化(回滚/清理)
#
# 性质
#  - 幂等:重复执行不会重复 commit / push,不会因为改过而再加补丁
#  - 配套依赖:/tmp/Compositor-Localizable.strings(脚本首次运行把项目里的 strings
#    备份到此;后续运行用之覆盖项目)。如果想重置,删除它。
#
set -euo pipefail

REPO="${REPO:-veelove/Compositor}"
BRANCH="${BRANCH:-main}"
PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ_DIR"

STRINGS_FILE="$PROJ_DIR/Compositor/zh-Hans.lproj/Localizable.strings"
BACKUP_STRINGS="/tmp/Compositor-Localizable.strings"

say()  { printf '\033[1;34m[zh-hans]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[zh-hans]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[zh-hans]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -d Compositor.xcodeproj ]] || die "未在 Compositor 仓库根目录运行"

# --------------------------------------------------------------------------
# RESTORE:卸载汉化(回滚到 ext 转使用 Text(\"Foo\") 等英文)
# --------------------------------------------------------------------------
if [[ "${RESTORE:-0}" == "1" ]]; then
  say "RESTORE=1,卸载汉化(从备份还原)"
  if [[ -f "$BACKUP_STRINGS" ]]; then
    cp "$BACKUP_STRINGS" "$STRINGS_FILE"
    say "已还原 strings"
  else
    rm -f "$STRINGS_FILE"
    say "无备份,删除 strings"
  fi
  rm -rf "$(dirname "$STRINGS_FILE")"
  rm -f "$PROJ_DIR/Compositor/Localization.swift"
  say "已删除 Localization.swift 与 zh-Hans.lproj"
  say "Swift 代码已保留 .localized 修饰(无副作用,不还原)"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "Remove zh-Hans localization"
    [[ "${SKIP_PUSH:-0}" == "1" ]] || git push
  fi
  exit 0
fi

# --------------------------------------------------------------------------
# 1. 备份项目里的原版 strings(若有),并写入正式翻译
# --------------------------------------------------------------------------
# 如果 strings 存在,但还没有备份,先备份
if [[ -f "$STRINGS_FILE" ]] && [[ ! -f "$BACKUP_STRINGS" ]]; then
  cp "$STRINGS_FILE" "$BACKUP_STRINGS"
  say "已备份 $STRINGS_FILE 到 $BACKUP_STRINGS"
fi
# 如果没有项目里的 strings,就要求本地有一份"模板",让脚本读出并备份
if [[ ! -f "$STRINGS_FILE" ]]; then
  if [[ -f "$BACKUP_STRINGS" ]]; then
    mkdir -p "$(dirname "$STRINGS_FILE")"
    cp "$BACKUP_STRINGS" "$STRINGS_FILE"
    say "从 $BACKUP_STRINGS 还原 $STRINGS_FILE"
  else
    die "未找到 $STRINGS_FILE 且无备份 $BACKUP_STRINGS。请先在本地写一份(可以从其他项目副本拷贝)"
  fi
fi

# --------------------------------------------------------------------------
# 4.5 给 Config/Info.plist 改 CFBundleDevelopmentRegion 为 zh-Hans + 加
#    CFBundleLocalizations (zh-Hans, en)
# 必要:macOS 在 developmentRegion=en 且只有 zh-Hans.lproj 时,NSBundle 的
# preferredLocalizations 会返回 en 而不是 zh-Hans,导致 NSLocalizedString 拿到
# 英文 key。改 developmentRegion 为 zh-Hans + 显式声明支持 zh-Hans 后,
# Bundle.preferredLocalizations 才会按系统语言偏好匹配。
# 注意:CFBundleDevelopmentRegion 不是用户可见的"语言",只是 bundle 的开发 region
#     元数据,改它不会影响界面文字。
# 实现:用 python plistlib(跨平台)替代 /usr/libexec/PlistBuddy——后者只在 macOS
#     上存在,Linux 服务器跑会报 command not found 并被 set -e 干掉。
# --------------------------------------------------------------------------
INFO_PLIST="$PROJ_DIR/Config/Info.plist"
if [[ -f "$INFO_PLIST" ]]; then
  python3 - "$INFO_PLIST" <<'PY'
import sys, plistlib
p = sys.argv[1]
with open(p, "rb") as f:
    data = plistlib.load(f)
changed = False
# developmentRegion -> zh-Hans
if data.get("CFBundleDevelopmentRegion") == "zh-Hans":
    print("[zh-hans] Info.plist CFBundleDevelopmentRegion 已是 zh-Hans,跳过")
else:
    data["CFBundleDevelopmentRegion"] = "zh-Hans"
    print("[zh-hans] Info.plist CFBundleDevelopmentRegion -> zh-Hans")
    changed = True
# CFBundleLocalizations -> [zh-Hans, en]
if "CFBundleLocalizations" in data:
    print("[zh-hans] Info.plist CFBundleLocalizations 已存在,跳过")
else:
    data["CFBundleLocalizations"] = ["zh-Hans", "en"]
    print("[zh-hans] Info.plist CFBundleLocalizations 已添加 [zh-Hans, en]")
    changed = True
if changed:
    with open(p, "wb") as f:
        plistlib.dump(data, f)
PY
fi

# --------------------------------------------------------------------------
# 4.6 给 Config/Compositor.entitlements 追加 disable-library-validation
# 必要:CI 的无签名构建是 ad-hoc(TEAM ID 为空)+ hardened runtime,dyld 会校验
#      嵌套框架的签名。主程序与 @rpath/Sparkle.framework 的 Team ID 不一致时,
#      启动即崩溃:
#        Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#        Reason: ... (non-platform) have different Team IDs
#      加该 entitlement 后 ad-hoc 构建即可加载不同签名的嵌套框架;
#      官方 Developer ID 版本本来就是同一个 Team ID,加上也不会有副作用。
# 实现:纯文本插入(不用 plistlib 重写整个文件),保留原有 XML 注释与缩进。
# --------------------------------------------------------------------------
ENTITLEMENTS_FILE="$PROJ_DIR/Config/Compositor.entitlements"
if [[ -f "$ENTITLEMENTS_FILE" ]]; then
  python3 - "$ENTITLEMENTS_FILE" <<'PY'
import sys
p = sys.argv[1]
key = "com.apple.security.cs.disable-library-validation"
txt = open(p, encoding="utf-8").read()
if key in txt:
    print("[zh-hans] entitlements 已有 disable-library-validation,跳过")
elif "</dict>" not in txt:
    print("[zh-hans] !! entitlements 里找不到 </dict>,未修改,请手工检查")
else:
    txt = txt.replace(
        "</dict>",
        "    <!-- ad-hoc 构建下放行不同 Team ID 的嵌套框架(Sparkle),否则 dyld 库校验会拒绝加载 -->\n"
        "    <key>%s</key>\n    <true/>\n</dict>" % key,
        1,
    )
    open(p, "w", encoding="utf-8").write(txt)
    print("[zh-hans] entitlements 已追加 disable-library-validation")
PY
fi

# --------------------------------------------------------------------------
# 2. 写 Localization.swift
# --------------------------------------------------------------------------
HELPER_FILE="$PROJ_DIR/Compositor/Localization.swift"
cat > "$HELPER_FILE" <<'EOF'
import Foundation

extension String {
    /// The translated text for this key from the app's Localizable.strings. The key is
    /// left as the English text, so English needs no table of its own: the literal is
    /// the fallback when a translation is missing.
    var localized: String { NSLocalizedString(self, comment: "") }
}
EOF
say "已写 Localization.swift"

# --------------------------------------------------------------------------
# 2.1 写 Credits.html:macOS 标准"关于"面板会在版本号下方显示这段文字
# --------------------------------------------------------------------------
CREDITS_FILE="$PROJ_DIR/Compositor/Credits.html"
cat > "$CREDITS_FILE" <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
body { font-family: -apple-system, "PingFang SC", sans-serif; text-align: center; }
</style>
</head>
<body>
<p>VUM星球汉化</p>
<p>WWW.VUMSTAR.COM</p>
</body>
</html>
EOF
say "已写 Credits.html(关于面板 VUM星球汉化 / WWW.VUMSTAR.COM)"

# --------------------------------------------------------------------------
# 3. 把 Localizable.strings 验证合法性(格式、冲突)
# --------------------------------------------------------------------------
python3 - <<'PY'
import re, sys
from collections import defaultdict
p = "Compositor/zh-Hans.lproj/Localizable.strings"
txt = open(p, encoding="utf-8").read()
lines = [l.strip() for l in txt.splitlines() if l.strip() and not l.strip().startswith("/*")]
bad = [l for l in lines if not re.fullmatch(r'"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', l)]
d = defaultdict(set)
for l in lines:
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', l)
    if m:
        d[m.group(1)].add(m.group(2))
conf = {k: v for k, v in d.items() if len(v) > 1}
if bad:
    print("BAD_LINES:", bad[:3]); sys.exit(2)
if conf:
    print("CONFLICT:", list(conf.items())[:3]); sys.exit(2)
print(f"OK unique={len(d.keys())}")
PY

# --------------------------------------------------------------------------
# 4. 给 pbxproj 加 knownRegions = zh-Hans,改 developmentRegion = zh-Hans(幂等)
# 改 developmentRegion 是关键:macOS 在 developmentRegion=en 时,NSBundle 会把 en
# 提到首选本地化,即使 zh-Hans.lproj 存在并匹配系统语言。
# --------------------------------------------------------------------------
PBXPROJ="$PROJ_DIR/Compositor.xcodeproj/project.pbxproj"
if grep -q '"zh-Hans"' "$PBXPROJ"; then
  say "pbxproj knownRegions 已含 zh-Hans,跳过"
else
  python3 - "$PBXPROJ" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
new = re.sub(
  r'(knownRegions\s*=\s*\(\s*\n\s*en,\s*\n\s*Base,\s*\n)(\s*)\);',
  r'\1        "zh-Hans",\n\2);',
  txt, flags=re.S)
if new == txt:
    sys.exit("pbxproj 里没找到 en, Base 块,需手动加 zh-Hans")
open(p, "w", encoding="utf-8").write(new)
PY
  say "pbxproj knownRegions 已加 zh-Hans"
fi

# 改 pbxproj developmentRegion: en -> "zh-Hans"。需要引号因为 "zh-Hans" 含连字符
# 不会被识别为 identifier(同 knownRegions 用法)。用 python 替换(BSD sed 在
# ^ + \s* 跨平台行为不可靠)。
if grep -q 'developmentRegion = "zh-Hans";' "$PBXPROJ"; then
  say "pbxproj developmentRegion 已是 zh-Hans,跳过"
elif grep -q 'developmentRegion = en;' "$PBXPROJ"; then
  python3 - "$PBXPROJ" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
new = re.sub(
  r'(?m)^(\s*)developmentRegion = en;',
  r'\1developmentRegion = "zh-Hans";',
  txt)
if new == txt:
    sys.exit("替换 pbxproj developmentRegion 失败")
open(p, "w", encoding="utf-8").write(new)
PY
  say "pbxproj developmentRegion: en -> zh-Hans"
else
  warn "pbxproj 没找到 developmentRegion 行,跳过"
fi

# --------------------------------------------------------------------------
# 5. Swift 代码补丁(幂等;对每条"原句" + 改后句"逐条匹配")
# --------------------------------------------------------------------------
patch_one() {
  local file="$1" before="$2" after="$3" count="${4:-1}"
  [[ -f "$file" ]] || { warn "$file 不存在,跳过"; return; }
  # 全部交给 python:处理 bash 中 \n 是字面两字符的问题,并区分
  # "已应用" / "未含原句" / "已替换" 三种情况,避免 sed 转义坑。
  # 第 4 个参数 count:替换次数上限,默认 1。>1 处理同一原文出现多次(如
  # firstLayer 里两处 ImageLayer(name: "Layer 1"))。本实现天然幂等——重复运行
  # 时无残余 before 就直接退出,不报错。
  local out
  if ! out=$(python3 - "$file" "$before" "$after" "$count" <<'PY'
import sys
p, before, after, count = sys.argv[1:]
# bash 双引号里的 \n 是字面两字符,还原为真实换行以匹配源码
before = before.replace("\\n", "\n")
after = after.replace("\\n", "\n")
count = int(count)
txt = open(p, encoding="utf-8").read()
# 幂等关键一步:先把已应用形态 after 还原成 before,再做替换。
# 否则当 after 以 before 为前缀时(最常见:deleteTitle = "Delete Mask" ->
# deleteTitle = "Delete Mask".localized),before 在打过补丁的源码里依然是子串,
# 每次重复运行都会再匹配一次,把 .localized 一层层叠成
# "Delete Mask".localized.localized.localized。还原后再替换则收敛。
# after 不以 before 为前缀的三元改写不受影响:第二次运行 txt.count(before)==0,
# 走下面"已全部应用"分支退出。
if after in txt:
    txt = txt.replace(after, before)
n_remaining = txt.count(before)
if n_remaining == 0:
    print("OK no remaining")        # 已全部应用(幂等)
    sys.exit(0)
n_remaining_total = n_remaining
n_replace = n_remaining if count <= 0 else min(count, n_remaining)
new = txt.replace(before, after, n_replace)
if new == txt:
    # before 出现但 replace 失败(罕见:原文与改后文本碰巧相同)。直接跳过。
    print("MISS same")
    sys.exit(0)
open(p, "w", encoding="utf-8").write(new)
print(f"OK replaced={n_replace}/{n_remaining_total}")
PY
  ); then
    warn "补丁失败: $file ($before)"
  elif [[ "$out" == MISS* ]]; then
    warn "$file 替换结果: $out ($before)"
  fi
}

# 5.1 枚举 localizedName
# 注意:不要做"文件级"幂等检查——同一文件有多个枚举时(Filters 有 FilterKind+
# BackgroundQuality 等),第一个加完属性后文件级 grep 会误判"已存在"而跳过其余,
# 导致 UI 已引用 .localizedName 但枚举没有该属性,编译报错。幂等判断交给 python
# 按枚举 body 检查。
add_enum_name() {
  local file="$1" enum="$2" name="$3" expr="${4:-rawValue.localized}"
  [[ -f "$file" ]] || return 0
  if ! python3 - "$file" "$enum" "$name" "$expr" <<'PY'
import re, sys
p, enum, name, expr = sys.argv[1:]
# 嵌套枚举(如 GridAppearance.Preset)声明时只写末段 Preset
match_name = enum.split(".")[-1]
txt = open(p, encoding="utf-8").read()
# 找到 enum 声明:兼容 nonisolated/public/private/final 等任意前缀
# 以及嵌套 enum(声明行带缩进)。
m = re.search(
  rf'(^|(?<=\n))([ \t]*)((?:nonisolated\s+|public\s+|private\s+|fileprivate\s+|internal\s+|final\s+)*enum {re.escape(match_name)})\s*:[^\n]*\{{',
  txt, re.M)
if not m:
    sys.exit(f"未在 {p} 找到 enum {enum}")
decl_indent = m.group(2)
# 括号计数定位匹配的闭合 },避免被内部 switch/闭包的花括号误导
depth = 1
i = m.end()
while i < len(txt) and depth > 0:
    if txt[i] == '{':
        depth += 1
    elif txt[i] == '}':
        depth -= 1
    i += 1
body = txt[m.end():i-1]
# 已有同名属性且表达式一致 -> 幂等跳过;表达式不同 -> 替换为期望表达式。
# 注意:Python 3.9 的 f-string 不支持 \{ 转义,这里用普通字符串拼接。
new_attr = f'var {name}: String {{ {expr} }}\n'
m2 = re.search(r"\bvar " + re.escape(name) + r": String\s*\{.*?\}\n", body)
if m2:
    cur = m2.group(0)
    # 已注入过同样的表达式 -> 直接退出,什么都不写。
    # 这里必须先做这次精确比对:属性体是 "String { rawValue.localized }"(带空格),
    # 而下面 re.search 比的是无空格的 "{"+expr+"}",永远不匹配,会让每次重复
    # 运行都重走替换分支;而 body/prefix 的重新拼接会吞掉 enum 声明行末尾的
    # "{",把源码改坏。
    if cur.strip() == new_attr.strip():
        sys.exit(0)
    if not re.search(re.escape("{" + expr + "}"), cur):
        body = body[:m2.start()] + new_attr + body[m2.end():]
        txt = txt[:m.end()-1] + body + txt[i-1:]
        open(p, "w", encoding="utf-8").write(txt)
elif f"var {name}: String" not in body:
    insert = f'\n{decl_indent}    /// The localized name.\n{decl_indent}    var {name}: String {{ {expr} }}\n'
    txt = txt[:i-1] + insert + txt[i-1:]
    open(p, "w", encoding="utf-8").write(txt)
PY
  then
    warn "跳过 enum $enum(未匹配)"
  fi
}

# 5.2 枚举 localizedName - NavigationTool 风格特殊(label 不是 rawValue)
add_label_for_toolbar() {
  local file="$1"
  [[ -f "$file" ]] || return
  grep -q 'NSLocalizedString("Type (T)"' "$file" && return 0
  if ! python3 - "$file" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
# NavigationTool.label: 单三元表达式,替换为 switch + NSLocalizedString
# 上游 PR #282 并入钢笔工具后三元里多出 .pen 分支;两种源码形态都要能匹配,
# 且只有源码含 .pen 时才生成 `case .pen`(否则 NavigationTool 无该 case,编译报错)。
head = 'var label: String { self == .type ? "Type (T)" : self == .eyedropper ? "Eyedropper (I)" : self == .marquee ? "Marquee (M)" : self == .lasso ? "Lasso (L)" : self == .wand ? "Magic (W) · Tab switches Wand and Object" : self == .brush ? "Brush (B) · Eraser (E)" : self == .spotHealing ? "Spot Healing Brush (J)" : self == .cloneStamp ? "Clone Stamp (S) · Option-click sets the source" : self == .blur ? "Smear (R)" : self == .gradient ? "Gradient (G)" : self == .shape ? "Shape (U) · Shift-U switches Rectangle/Ellipse"'
pen_part = ' : self == .pen ? "Pen (P) · Tab switches Draw, Bend, Cut and Erase"'
tail = ' : self == .crop ? "Crop (C)" : self == .move ? "Move / Transform (V)" : self == .hand ? "Hand (H)" : "Zoom (Z)" }'
has_pen = (head + pen_part + tail) in txt
old = head + (pen_part if has_pen else "") + tail
if old not in txt:
    sys.exit("未找到 NavigationTool.label 原句")
new = '''var label: String {
        switch self {
        case .type: return NSLocalizedString("Type (T)", comment: "")
        case .eyedropper: return NSLocalizedString("Eyedropper (I)", comment: "")
        case .marquee: return NSLocalizedString("Marquee (M)", comment: "")
        case .lasso: return NSLocalizedString("Lasso (L)", comment: "")
        case .wand: return NSLocalizedString("Magic (W) · Tab switches Wand and Object", comment: "")
        case .brush: return NSLocalizedString("Brush (B) · Eraser (E)", comment: "")
        case .spotHealing: return NSLocalizedString("Spot Healing Brush (J)", comment: "")
        case .cloneStamp: return NSLocalizedString("Clone Stamp (S) · Option-click sets the source", comment: "")
        case .blur: return NSLocalizedString("Smear (R)", comment: "")
        case .gradient: return NSLocalizedString("Gradient (G)", comment: "")
        case .shape: return NSLocalizedString("Shape (U) · Shift-U switches Rectangle/Ellipse", comment: "")
%%PEN%%
        case .crop: return NSLocalizedString("Crop (C)", comment: "")
        case .move: return NSLocalizedString("Move / Transform (V)", comment: "")
        case .hand: return NSLocalizedString("Hand (H)", comment: "")
        default: return NSLocalizedString("Zoom (Z)", comment: "")
        }
    }'''
new = new.replace("%%PEN%%\n", '        case .pen: return NSLocalizedString("Pen (P) · Tab switches Draw, Bend, Cut and Erase", comment: "")\n' if has_pen else "")
txt = txt.replace(old, new)
open(p, "w", encoding="utf-8").write(txt)
PY
  then
    warn "跳过 NavigationTool.label(未匹配)"
  fi
}

add_label_for_toolbar Compositor/Document/EditorSession.swift

# 5.2.5 BlendModePicker:菜单项显示中文,但 NSPopUpButton 用标题反查枚举,
# 所以显示 localizedName 的同时把枚举存进 representedObject,反查用
# representedObject 而不是 rawValue(与 f04a59f 一致)。
patch_blend_mode_picker() {
  local file="Compositor/UI/BlendModePicker.swift"
  [[ -f "$file" ]] || return
  grep -q "representedObject" "$file" && return 0
  if ! python3 - "$file" <<'PY'
import sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
repl = [
  # 菜单项:显示本地化名,同时把枚举存进 representedObject
  ("            for mode in group { button.addItem(withTitle: mode.rawValue) }",
   "            for mode in group {\n                button.addItem(withTitle: mode.localizedName)\n                button.itemArray.last?.representedObject = mode\n            }"),
  # 无障碍标签本地化
  ('        button.setAccessibilityLabel("Blend mode")',
   '        button.setAccessibilityLabel("Blend mode".localized)'),
  # 当前选中项用本地化名定位
  ("            button.selectItem(withTitle: (session.activeLayer?.blendMode ?? .normal).rawValue)",
   "            button.selectItem(withTitle: (session.activeLayer?.blendMode ?? .normal).localizedName)"),
  # 高亮反查:用 representedObject
  ('            guard let mode = item.flatMap({ LayerBlendMode(rawValue: $0.title) }) else { return }',
   "            guard let mode = item.flatMap({ $0.representedObject as? LayerBlendMode }) else { return }"),
  # 提交时反查:用 representedObject
  ("                  let mode = highlightedMode ?? button.selectedItem.flatMap({ LayerBlendMode(rawValue: $0.title) }) else { return }",
   "                  let mode = highlightedMode ?? button.selectedItem.flatMap({ $0.representedObject as? LayerBlendMode }) else { return }"),
  # 提交后选中项也用本地化名
  ("            button.selectItem(withTitle: mode.rawValue)",
   "            button.selectItem(withTitle: mode.localizedName)"),
]
for old, new in repl:
    if old in txt:
        txt = txt.replace(old, new, 1)
    else:
        print("MISS:", old[:60])
open(p, "w", encoding="utf-8").write(txt)
PY
  then
    warn "BlendModePicker 补丁失败"
  fi
}

patch_blend_mode_picker

# 5.2.6 混合模式面板"Blend"标签 + 新建画布背景 + 菜单"Layer"
patch_one Compositor/UI/LayerAppearanceControls.swift \
  'Text("Blend").font(.caption)' \
  'Text("Blend".localized).font(.caption)'

patch_one Compositor/CompositorApp.swift \
  'CommandMenu("Layer") {' \
  'CommandMenu("Layer".localized) {'

# 5.2.8 状态栏工具提示:ContentView 里是一大串运行时三元表达式,Text(String)
# 不会自动本地化。替换为 Text(hint(for: session)),并加 hint(for:) 方法,
# 方法与 f04a59f 一致(全部用 NSLocalizedString)。
patch_content_view_hint() {
  local file="Compositor/ContentView.swift"
  [[ -f "$file" ]] || return
  grep -q "func hint(for session" "$file" && return 0
  if ! python3 - "$file" <<'PY'
import sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()

# 1) 替换大三元 Text(...) 为 Text(hint(for: session))
import re
# 上游 PR #282 并入钢笔工具后,三元里才有 .pen 分支;未并入时不能生成
# `case .pen`(NavigationTool 没有该 case,会编译报错)。
has_pen = "session.tool == .pen" in txt
pen_case = '''        case .pen:
            switch session.penAction {
            case .draw:
                return NSLocalizedString("Click points · Drag curves · Click the first point to close · Double-click or Return to finish open · Double-click an existing point to smooth · ⌘Return loads selection", comment: "")
            case .bend:
                return NSLocalizedString("Drag a path segment to bend it · ⌘Z undo · Tab changes path tool", comment: "")
            case .cut:
                return NSLocalizedString("Click a path segment to cut it · Closed paths open; open paths split into separate pieces · ⌘Z undo", comment: "")
            case .erase:
                return NSLocalizedString("Drag the circular eraser across the selected path · [ ] size · Right-drag size · Escape returns to Draw · ⌘Z undo", comment: "")
            }
''' if has_pen else ""
m = re.search(r'Text\(session\.tool == \.marquee \? .*?Space to pan"\)', txt, re.S)
if m:
    txt = txt[:m.start()] + "Text(hint(for: session))" + txt[m.end():]
else:
    print("MISS: big ternary")
    sys.exit(0)

# 2) 在 status bar 视图的结尾(accessibilityElement...} 之后、struct } 之前)插入方法
method = '''
    /// The status bar's tool hint, localized. Built from NSLocalizedString so the
    /// runtime-computed string still resolves against Localizable.strings.
    private func hint(for session: EditorSession) -> String {
        switch session.tool {
        case .marquee:
            return session.marqueeKind == .ellipse
                ? NSLocalizedString("Drag an ellipse · Shift add · Option subtract · Shift again mid-drag circle · Drag inside to move · Delete clears · ⌘D deselect", comment: "")
                : NSLocalizedString("Drag a rectangle · Shift add · Option subtract · Shift again mid-drag square · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect", comment: "")
        case .wand:
            return session.wandMode == .object
                ? NSLocalizedString("Click an object to select its outline · Tab for Wand · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect", comment: "")
                : NSLocalizedString("Click to select similar colors · Tab for Object · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect", comment: "")
        case .lasso:
            return session.lassoKind == .freehand
                ? NSLocalizedString("Drag to select · Drag inside to move · Shift add · Option subtract · Delete clears · ⌥⌫/⌘⌫ fill · ⌘D deselect", comment: "")
                : NSLocalizedString("Click corners · Click start, double-click or Enter to close · Delete removes corner · Escape cancel", comment: "")
        case .brush:
            let action = session.brushMode == .erase
                ? NSLocalizedString("Drag to erase", comment: "")
                : NSLocalizedString("Drag to paint", comment: "")
            return action + NSLocalizedString(" · [ ] size · Shift-[ ] hardness · 1–0 opacity · Escape cancel · Space to pan", comment: "")
        case .blur:
            let action = session.blurMode == .blur
                ? NSLocalizedString("Drag to soften", comment: "")
                : session.blurMode == .smudge ? NSLocalizedString("Drag to smudge", comment: "")
                : NSLocalizedString("Drag to push pixels", comment: "")
            return action + NSLocalizedString(" · [ ] size · Shift-[ ] hardness · 1–0 strength · Space to pan", comment: "")
        case .cloneStamp:
            return NSLocalizedString("Option-click to set the source · Drag to clone · [ ] size · Shift-[ ] hardness · 1–0 opacity · Space to pan", comment: "")
        case .spotHealing:
            return NSLocalizedString("Drag over blemishes to heal · [ ] size · Shift-[ ] hardness · Escape cancel · Space to pan", comment: "")
        case .type:
            return NSLocalizedString("Drag a text box · Click text to edit · Drag box handles to resize · ⌘Return finish · Escape cancel", comment: "")
        case .shape:
            let shape = session.shapeKind == .line ? NSLocalizedString("45°", comment: "")
                : session.shapeKind == .rectangle ? NSLocalizedString("square", comment: "")
                : NSLocalizedString("circle", comment: "")
            return String.localizedStringWithFormat(NSLocalizedString("Drag to draw a shape on a new layer · Shift %@ · Option from center · Shift-U or Tab for the next shape · Escape cancel · Space to pan", comment: ""), shape)
%%PEN_CASE%%
        case .gradient:
            return NSLocalizedString("Drag to draw · Drag ends to adjust · Shift 45° · 1–0 opacity · Enter apply · Escape cancel", comment: "")
        case .crop:
            return NSLocalizedString("Drag to crop · Enter apply · Escape cancel · Space to pan", comment: "")
        case .move:
            return NSLocalizedString("Drag to move · Handles to resize · Circle to rotate · 1–0 layer opacity · Space to pan", comment: "")
        case .hand:
            return NSLocalizedString("Drag to pan · Pinch to zoom", comment: "")
        case .idle:
            return NSLocalizedString("No tool selected · Press a tool's key to pick one · Space to pan", comment: "")
        default:
            return NSLocalizedString("Click to zoom in · Option-click to zoom out · Drag right or left to zoom smoothly · Space to pan", comment: "")
        }
    }
'''
method = method.replace("%%PEN_CASE%%\n", pen_case)

anchor = ".accessibilityElement(children: .contain)\n    }\n}"
if anchor in txt:
    txt = txt.replace(anchor, ".accessibilityElement(children: .contain)\n    }" + method + "}", 1)
else:
    print("MISS: anchor")
open(p, "w", encoding="utf-8").write(txt)
PY
  then
    warn "ContentView 提示补丁失败"
  fi
}

patch_content_view_hint

# 5.2.7 Image / Filter 菜单:菜单项是运行时拼接("\(kind.rawValue)…"),
# 不会自动本地化,改成 localizedName + "…"。
# Image 和 Filter 两个 ForEach 里都有这一行,python 替换全部出现。
if ! python3 - Compositor/CompositorApp.swift <<'PY'
import sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
old = 'Button("\\(kind.rawValue)…") { session.beginFilter(kind) }'
new = 'Button(kind.localizedName + "…") { session.beginFilter(kind) }'
n = txt.count(old)
if n:
    txt = txt.replace(old, new)
    open(p, "w", encoding="utf-8").write(txt)
print("replaced", n)
PY
then
  warn "CompositorApp 菜单补丁失败"
fi

# Last Filter:上次滤镜
patch_one Compositor/CompositorApp.swift \
  'Button(session.lastFilter.map { "Last Filter: " + $0.rawValue } ?? "Last Filter") {' \
  'Button(session.lastFilter.map { String.localizedStringWithFormat(NSLocalizedString("Last Filter: %@", comment: ""), $0.localizedName) } ?? "Last Filter".localized) {'

# Delete Layer 按钮(运行时拼接,不自动本地化)
patch_one Compositor/CompositorApp.swift \
  'Button(session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer") {' \
  'Button(session.selectedEffect != nil ? String.localizedStringWithFormat(NSLocalizedString("Delete %@", comment: ""), session.selectedEffect!.kind.localizedName) : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask".localized : session.selectedLayerIDs.count > 1 ? "Delete Layers".localized : "Delete Layer".localized) {'

# 图层右键菜单:Delete 标题(NSMenuItem 运行时字符串)
patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Mask"' \
  'deleteTitle = "Delete Mask".localized'
patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Selected Layers"' \
  'deleteTitle = "Delete Selected Layers".localized'
patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Layer"' \
  'deleteTitle = "Delete Layer".localized'

# Merge Down 标题
patch_one Compositor/Document/LayerMerge.swift \
  'var mergeTitle: String { mergePlan()?.action ?? "Merge Down" }' \
  'var mergeTitle: String { mergePlan()?.action.localized ?? "Merge Down".localized }'

# NativeLayerList — 图层右键菜单所有 NSMenuItem 标题(运行时字符串不自动本地化)
python3 - Compositor/UI/NativeLayerList.swift <<'PY'
import sys, re
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
# 给 NSMenuItem(title: "...") 的字符串加 .localized,跳过已加过的。
# 幂等要点:必须判断字面量后面是否已经跟着 .localized,否则重复运行会把
# "Add Mask" 叠成 "Add Mask".localized.localized(这一段没有 keys 白名单,
# 匹配到的每个 NSMenuItem 都会再叠一层)。
def fix(m):
    inner = m.group(1)
    end = m.end()
    if txt[end:end + len(".localized")] == ".localized":
        return m.group(0)
    return 'NSMenuItem(title: ' + inner + '.localized'
new = re.sub(r'NSMenuItem\(title: ("[^"]*")', fix, txt)
if new != txt:
    open(p, "w", encoding="utf-8").write(new)
print("NSMenuItem fixed" if new != txt else "NSMenuItem noop")
PY

# NewCanvasBackground: "\(rawValue.capitalized) canvas" 是动态拼接,
# 用 .localized 查表("Transparent canvas" / "Black canvas" / "White canvas")。
patch_one Compositor/UI/NewCanvasSheet.swift \
  'CyclePill(background.title, help:' \
  'CyclePill(background.title.localized, help:'

# NewCanvasSheet 单位 pill(Pixels/Inches/...):用枚举的 localizedName 而非 name。
patch_one Compositor/UI/NewCanvasSheet.swift \
  'CyclePill(unit.name, help:' \
  'CyclePill(unit.localizedName, help:'


# 5.3 各枚举LocalizedName
# 第三列为可选的 localizedName 表达式;默认 rawValue.localized。
# WandSampleSize 的 rawValue 是 Int(无 .localized),必须用 title.localized。
for line in \
  "Compositor/Document/Filters.swift            FilterKind" \
  "Compositor/Document/LayerAdjustment.swift    AdjustmentKind" \
  "Compositor/Document/LayerEffects.swift       LayerEffectKind" \
  "Compositor/Document/LayerAppearance.swift    LayerBlendMode" \
  "Compositor/Document/Selection.swift          LassoKind" \
  "Compositor/Document/Selection.swift          WandMode" \
  "Compositor/Document/Selection.swift          SelectionMode" \
  "Compositor/Document/BrushStroke.swift        SpotHealingMode" \
  "Compositor/Document/SmudgeLiquify.swift      BrushToolMode" \
  "Compositor/Document/SmudgeLiquify.swift      BlurToolMode" \
  "Compositor/Document/CameraRaw.swift          CameraRawWhiteBalance" \
  "Compositor/Document/CameraRaw.swift          CameraRawGlowStyle" \
  "Compositor/Document/CameraRaw.swift          CameraRawVignetteStyle" \
  "Compositor/Document/CameraRawColor.swift     CameraRawCurvePage" \
  "Compositor/Document/CameraRawColor.swift     CameraRawPointChannel" \
  "Compositor/Document/CameraRawColor.swift     CameraRawMixerPage" \
  "Compositor/Document/CameraRawColor.swift     CameraRawMixerTab" \
  "Compositor/Document/CameraRawColor.swift     CameraRawGradePage" \
  "Compositor/Document/ImageTrim.swift          TrimBasedOn" \
  "Compositor/Document/LayerTransform.swift     LayerSampling" \
  "Compositor/Document/Levels.swift             LevelsChannel" \
  "Compositor/Document/Dither.swift             DitherStyle" \
  "Compositor/Document/Dither.swift             DitherPixelShape" \
  "Compositor/Document/Dither.swift             DitherColors" \
  "Compositor/Document/Filters.swift            BackgroundQuality" \
  "Compositor/Document/HueSaturation.swift      HueSampleMode" \
  "Compositor/Document/HueSaturation.swift      ColorRange" \
  "Compositor/Document/Gradient.swift           GradientStyle" \
  "Compositor/Document/Gradient.swift           GradientShape" \
  "Compositor/Document/CanvasSize.swift         CanvasUnit" \
  "Compositor/Document/CameraRawGeometryCalibration.swift CameraRawUprightMode" \
  "Compositor/Document/CameraRawGeometryCalibration.swift CameraRawProjection" \
  "Compositor/Document/CameraRawGeometryCalibration.swift CameraRawProcessVersion" \
  "Compositor/Document/Guides.swift             GridAppearance.Preset" \
  "Compositor/Document/Guides.swift             GridAppearance.Style" \
  "Compositor/Document/ShapeTool.swift          ShapeKind" \
  "Compositor/Document/ShapeTool.swift          ShapeLineStyle" \
  "Compositor/Document/ShapeTool.swift          ShapeLineCap" \
  "Compositor/Document/PenTool.swift            PenAction" \
  "Compositor/Document/LevelsAutomatic.swift    LevelsSample" \
  "Compositor/Document/LevelsAutomatic.swift    LevelsAuto" \
  "Compositor/UI/CameraRawControls.swift        CameraRawControls.Section" \
  "Compositor/UI/NewCanvasSheet.swift           NewCanvasUnit          name.localized" \
  "Compositor/Document/MagicWand.swift          WandSampleSize        title.localized"; do
  file=$(echo "$line" | awk '{print $1}')
  enum=$(echo "$line" | awk '{print $2}')
  expr=$(echo "$line" | awk '{print $3}')
  add_enum_name "$file" "$enum" "localizedName" "$expr"
done

# 5.4 SwiftUI 调用点 .rawValue / .title 改 .localizedName
patch_one Compositor/UI/LassoControls.swift \
  "ForEach(LassoKind.marqueeChoices, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(LassoKind.marqueeChoices, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LassoControls.swift \
  "ForEach(WandMode.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(WandMode.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LassoControls.swift \
  "ForEach(LassoKind.lassoChoices, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(LassoKind.lassoChoices, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LassoControls.swift \
  "ForEach(SelectionMode.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(SelectionMode.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LassoControls.swift \
  "ForEach(WandSampleSize.allCases, id: \\.self) { Text(\$0.title).tag(\$0) }" \
  "ForEach(WandSampleSize.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LassoControls.swift \
  "modifyControl(\"Expand\", amount:" "modifyControl(\"Expand\".localized, amount:"
patch_one Compositor/UI/LassoControls.swift \
  "modifyControl(\"Contract\", amount:" "modifyControl(\"Contract\".localized, amount:"
patch_one Compositor/UI/LassoControls.swift \
  "Toggle(\"Contiguous\", isOn:" "Toggle(\"Contiguous\".localized, isOn:"

# LevelsSheet
patch_one Compositor/UI/LevelsSheet.swift \
  "ForEach(LevelsChannel.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(LevelsChannel.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/LevelsSheet.swift \
  "ForEach(LevelsAuto.allCases, id: \\.self) { mode in\n                        Button(mode.rawValue)" \
  "ForEach(LevelsAuto.allCases, id: \\.self) { mode in\n                        Button(mode.localizedName)"
patch_one Compositor/UI/LevelsSheet.swift \
  "Label(mode.rawValue, systemImage: \"eyedropper\")" "Label(mode.localizedName, systemImage: \"eyedropper\")"

# ShapeControls
patch_one Compositor/UI/ShapeControls.swift \
  "ForEach(ShapeKind.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(ShapeKind.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"

# HueSaturationSheet
patch_one Compositor/UI/HueSaturationSheet.swift \
  "ForEach(ColorRange.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(ColorRange.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"

# CanvasSizeSheet
patch_one Compositor/UI/CanvasSizeSheet.swift \
  "ForEach(CanvasUnit.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(CanvasUnit.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"

# GradientControls
patch_one Compositor/UI/GradientControls.swift \
  "ForEach(GradientShape.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(GradientShape.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/GradientControls.swift \
  "ForEach(GradientStyle.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(GradientStyle.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/GradientControls.swift \
  "Toggle(\"Reverse\", isOn: \$session.gradientSettings.reversed)" \
  "Toggle(\"Reverse\".localized, isOn: \$session.gradientSettings.reversed)"

# FilterSheet
patch_one Compositor/UI/FilterSheet.swift \
  "Toggle(\"Reverse\", isOn: \$settings.reversed)" \
  "Toggle(\"Reverse\".localized, isOn: \$settings.reversed)"
patch_one Compositor/UI/FilterSheet.swift \
  "ForEach(BackgroundQuality.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(BackgroundQuality.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/FilterSheet.swift \
  "ForEach(DitherStyle.groups[group], id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(DitherStyle.groups[group], id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/FilterSheet.swift \
  "ForEach(DitherColors.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(DitherColors.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/FilterSheet.swift \
  "ForEach(DitherPixelShape.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(DitherPixelShape.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"

# ImageSizeSheet
patch_one Compositor/UI/ImageSizeSheet.swift \
  "ForEach(LayerSampling.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(LayerSampling.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/ImageSizeSheet.swift \
  'ForEach(units.filter { resample || ($0 != "Pixels" && $0 != "Percent") }, id: \.self) { Text($0) }' \
  'ForEach(units.filter { resample || ($0 != "Pixels" && $0 != "Percent") }, id: \.self) { Text($0.localized) }'

# TransformInspector — LayerSampling (Smooth / Nearest / High quality)
patch_one Compositor/UI/TransformInspector.swift \
  "ForEach(LayerSampling.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(LayerSampling.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"

# BrushControls — 模式选择器(Paint/Erase、Liquify/Blur/Smudge、Content-Aware/Create Texture/Proximity Match)
patch_one Compositor/UI/BrushControls.swift \
  "ForEach(BrushToolMode.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(BrushToolMode.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/BrushControls.swift \
  "ForEach(BlurToolMode.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(BlurToolMode.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/BrushControls.swift \
  "ForEach(SpotHealingMode.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(SpotHealingMode.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"


# CropControls
patch_one Compositor/UI/CropControls.swift \
  'ForEach(["Free", "Original", "1:1", "4:3", "3:4", "16:9", "9:16"], id: \.self) { Text($0) }' \
  'ForEach(["Free", "Original", "1:1", "4:3", "3:4", "16:9", "9:16"], id: \.self) { Text($0.localized) }'

# CanvasSizeSheet - 画布扩展背景色
patch_one Compositor/UI/CanvasSizeSheet.swift \
  'ForEach(["Transparent", "Foreground", "Background", "Black", "White", "Custom"], id: \.self) { Text($0) }' \
  'ForEach(["Transparent", "Foreground", "Background", "Black", "White", "Custom"], id: \.self) { Text($0.localized) }'

# CameraRawColorControls
for kind in CameraRawCurvePage CameraRawPointChannel CameraRawMixerPage CameraRawMixerTab CameraRawGradePage; do
  patch_one Compositor/UI/CameraRawColorControls.swift \
    "ForEach(${kind}.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
    "ForEach(${kind}.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
done

# CameraRawControls
patch_one Compositor/UI/CameraRawControls.swift \
  "ForEach(CameraRawWhiteBalance.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(CameraRawWhiteBalance.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/CameraRawControls.swift \
  "ForEach(CameraRawGlowStyle.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(CameraRawGlowStyle.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/CameraRawControls.swift \
  "ForEach(CameraRawVignetteStyle.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(CameraRawVignetteStyle.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/CameraRawControls.swift \
  "Text(section.rawValue).font(.headline)" "Text(section.localizedName).font(.headline)"
patch_one Compositor/UI/CameraRawControls.swift \
  ".accessibilityLabel(section.rawValue)" ".accessibilityLabel(section.localizedName)"

# CameraRawGeometryCalibrationControls
for kind in CameraRawUprightMode CameraRawProjection CameraRawProcessVersion; do
  patch_one Compositor/UI/CameraRawGeometryCalibrationControls.swift \
    "ForEach(${kind}.allCases, id: \\.self) { Text(\$0.rawValue).tag(\$0) }" \
    "ForEach(${kind}.allCases, id: \\.self) { Text(\$0.localizedName).tag(\$0) }"
done

# GridSettingsSheet
patch_one Compositor/UI/GridSettingsSheet.swift \
  "ForEach(GridAppearance.Preset.allCases) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(GridAppearance.Preset.allCases) { Text(\$0.localizedName).tag(\$0) }"
patch_one Compositor/UI/GridSettingsSheet.swift \
  "ForEach(GridAppearance.Style.allCases) { Text(\$0.rawValue).tag(\$0) }" \
  "ForEach(GridAppearance.Style.allCases) { Text(\$0.localizedName).tag(\$0) }"

# BrushControls — 工具名三元 + 全 .localized 改
patch_one Compositor/UI/BrushControls.swift \
  'Text(session.tool == .spotHealing ? "Spot Healing" : session.tool == .cloneStamp ? "Clone Stamp" : session.tool == .blur ? "Smear" : session.brushMode == .erase ? "Eraser" : "Brush").font(ToolHeaderStyle.titleFont)' \
  'Text(session.tool == .spotHealing ? "Spot Healing".localized : session.tool == .cloneStamp ? "Clone Stamp".localized : session.tool == .blur ? "Smear".localized : session.brushMode == .erase ? "Eraser".localized : "Brush".localized).font(ToolHeaderStyle.titleFont)'

# TrimSheet
patch_one Compositor/UI/TrimSheet.swift \
  "ForEach(TrimBasedOn.allCases) { option in\n                        Text(option.rawValue).tag(option)" \
  "ForEach(TrimBasedOn.allCases) { option in\n                        Text(option.localizedName).tag(option)"

# NavigationToolHeader
patch_one Compositor/UI/NavigationToolHeader.swift \
  'Text(session.tool == .hand ? "Pan" : "Zoom").font(ToolHeaderStyle.titleFont)' \
  'Text(session.tool == .hand ? "Pan".localized : "Zoom".localized).font(ToolHeaderStyle.titleFont)'

# ProjectTabs
patch_one Compositor/UI/ProjectTabs.swift \
  'Label("New", systemImage: "plus")' 'Label("New".localized, systemImage: "plus")'

# CommandPalette — Tool id
patch_one Compositor/UI/CommandPalette.swift \
  'CommandPaletteEntry(id: "Tool › \(name)", shortcut:' \
  'CommandPaletteEntry(id: ("Tool › " + name).localized, shortcut:'

# LayersPanel — AdjustmentKind 菜单
patch_one Compositor/UI/LayersPanel.swift \
  "ForEach(AdjustmentKind.allCases, id: \\.self) { kind in\n                        Button(kind.rawValue) { session.addAdjustment(kind) }" \
  "ForEach(AdjustmentKind.allCases, id: \\.self) { kind in\n                        Button(kind.localizedName) { session.addAdjustment(kind) }"

# LayersPanel — 添加图层效果菜单(Stroke…/Drop Shadow… 等,运行时拼接不自动本地化)
patch_one Compositor/UI/LayersPanel.swift \
  'Button(kind.rawValue + "…") { session.addEffect(kind) }' \
  'Button(kind.localizedName + "…") { session.addEffect(kind) }'

# ColorPaletteControls — 前景/背景色标签(运行时三元)
patch_one Compositor/UI/ColorPaletteControls.swift \
  'let label = background ? "Background color" : "Foreground color"' \
  'let label = (background ? "Background color" : "Foreground color").localized'

# ContentView — 窗口标题的 Untitled 兜底(运行时字符串不自动本地化)
patch_one Compositor/ContentView.swift \
  '.navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")' \
  '.navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled".localized)'

# NewCanvasSheet
patch_one Compositor/UI/NewCanvasSheet.swift \
  'Text(unit.rawValue).foregroundStyle(.secondary)' \
  'Text(unit.localizedName).foregroundStyle(.secondary)'

# TransformInspector — Scale 字段
patch_one Compositor/UI/TransformInspector.swift \
  'TransformValueField(label: "Scale", suffix: "%", value: value.scalePercent(pixelSize: pixelSize), range: 0.1...30_000, finish: finish) { number in' \
  'TransformValueField(label: "Scale".localized, suffix: "%", value: value.scalePercent(pixelSize: pixelSize), range: 0.1...30_000, finish: finish) { number in'

# beginEdit 入口(历史名本地化)
patch_one Compositor/Document/EditorSession.swift \
  "history.begin(name, document: document, selection: activeLayerID)" \
  "history.begin(name.localized, document: document, selection: activeLayerID)"

# 新建图层命名:"Layer \(number)" 是运行时拼接,且每次数字不同,不能用固定 key,
# 用 "Layer %d" 格式化 + 本地化。names.contains 检查也要同步本地化,
# 否则检查的是英文名、存的是中文名,编号会重复。
patch_one Compositor/Document/EditorSession.swift \
  'while names.contains("Layer \(number)") { number += 1 }\n        var layer = ImageLayer(name: "Layer \(number)", blankSize: document.size)' \
  'while names.contains(String.localizedStringWithFormat(NSLocalizedString("Layer %d", comment: ""), number)) { number += 1 }\n        var layer = ImageLayer(name: String.localizedStringWithFormat(NSLocalizedString("Layer %d", comment: ""), number), blankSize: document.size)'

# SelectionClipboard — 粘贴/复制图层的命名(同样两处)
patch_one Compositor/Document/SelectionClipboard.swift \
  'while names.contains("Layer \(number)") { number += 1 }\n        return "Layer \(number)"' \
  'while names.contains(String.localizedStringWithFormat(NSLocalizedString("Layer %d", comment: ""), number)) { number += 1 }\n        return String.localizedStringWithFormat(NSLocalizedString("Layer %d", comment: ""), number)'

# PSDReader — 无名字段的兜底 "Layer"
patch_one Compositor/IO/PSD/PSDReader.swift \
  '?? "Layer"' \
  '?? "Layer".localized'

# TypeTool — 文本图层默认名 "Text"
patch_one Compositor/Document/TypeTool.swift \
  'return flattened.isEmpty ? "Text" : String(flattened.prefix(40))' \
  'return flattened.isEmpty ? "Text".localized : String(flattened.prefix(40))'

# --------------------------------------------------------------------------
# 5.7 钢笔工具(上游 PR #282):控件、提示、撤销名与图层名
# PR #282 新增 PenControls.swift / PenTool.swift,其中的界面文案不在
# Localizable.strings 里,也不走通用规则,这里逐条补齐。
# --------------------------------------------------------------------------

# 仅在并入钢笔工具(存在 PenControls.swift)时应用;未并入时这些文件不存在。
if [[ -f Compositor/UI/PenControls.swift ]]; then
# 动作分段控件 Draw/Bend/Cut/Erase 走 PenAction.rawValue(运行时 String,
# Text 不会自动本地化),改为 localizedName(由 5.3 add_enum_name 注入)。
patch_one Compositor/UI/PenControls.swift \
  'Text(action.rawValue).tag(action)' \
  'Text(action.localizedName).tag(action)'

# 描边提示带运行时插值(画笔直径),5.12 的 .help() 规则会跳过,改用格式化 key。
patch_one Compositor/UI/PenControls.swift \
  '.help("Add or update an editable path stroke using the current \(Int(session.brushSettings.diameter.rounded())) px Brush, hardness and opacity")' \
  '.help(String.localizedStringWithFormat(NSLocalizedString("Add or update an editable path stroke using the current %@ px Brush, hardness and opacity", comment: ""), String(Int(session.brushSettings.diameter.rounded()))))'

# 载入路径为选区时的选区名(撤销名已由 history.begin(name.localized) 覆盖)。
patch_one Compositor/Document/PenTool.swift \
  'applySelection(path, mode: mode, name: "Load Path Selection")' \
  'applySelection(path, mode: mode, name: "Load Path Selection".localized)'

# 新建矢量路径图层名 "Path"(编号形式 "Path 1")与描边临时图层 "Path Stroke"。
patch_one Compositor/Document/PenTool.swift \
  'nextPenResultName("Path")' \
  'nextPenResultName("Path".localized)'

patch_one Compositor/Document/PenTool.swift \
  'let blank = ImageLayer(name: "Path Stroke", blankSize: drawSize)' \
  'let blank = ImageLayer(name: "Path Stroke".localized, blankSize: drawSize)'

# EditorSession.canUndoPenClosure 用 undoName 字面量比较,撤销名本地化后
# 必须比较本地化值,否则"撤销闭合路径"会失效。
patch_one Compositor/Document/EditorSession.swift \
  'guard tool == .pen, penDraft == nil, history.undoName == "Path",' \
  'guard tool == .pen, penDraft == nil, history.undoName == "Path".localized,'
fi

# EditorSession.firstLayer — 新建画布时的初始图层(硬编码 "Layer 1")。
# 跳过 addBlankLayer 的编号循环,直接用第 1 个图层名。这里出现两次(空背景回退、
# 填充背景失败回退),所以 count > 1。
patch_one Compositor/Document/EditorSession.swift \
  'ImageLayer(name: "Layer 1", blankSize: size)' \
  'ImageLayer(name: String.localizedStringWithFormat(NSLocalizedString("Layer %d", comment: ""), 1), blankSize: size)' \
  2

# EditorSession.firstLayer — 画布背景图层 "Background"(name 字段两处)
patch_one Compositor/Document/EditorSession.swift \
  'name: "Background"' \
  'name: "Background".localized' \
  2

# --------------------------------------------------------------------------
# 5.9 对话框 / 面板标题(NSAlert、NSOpenPanel/NSSavePanel)
# 这些字符串传给的是 String 参数(addButton(withTitle:)、title=),不走 SwiftUI
# 的 LocalizedStringKey 自动本地化,必须显式 .localized / NSLocalizedString。
# --------------------------------------------------------------------------
patch_one Compositor/IO/ProjectController.swift \
  'alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"\n        alert.informativeText = "Your changes will be lost if you don’t save them."\n        alert.addButton(withTitle: "Save")\n        alert.addButton(withTitle: "Cancel")\n        alert.addButton(withTitle: "Don’t Save")' \
  'alert.messageText = String.localizedStringWithFormat(NSLocalizedString("Save changes to %@?", comment: ""), session.projectURL?.lastPathComponent ?? "Untitled".localized)\n        alert.informativeText = "Your changes will be lost if you don’t save them.".localized\n        alert.addButton(withTitle: "Save".localized)\n        alert.addButton(withTitle: "Cancel".localized)\n        alert.addButton(withTitle: "Don’t Save".localized)'

patch_one Compositor/IO/ProjectController.swift \
  'alert.informativeText = error.localizedDescription\n        alert.addButton(withTitle: "OK")' \
  'alert.informativeText = error.localizedDescription\n        alert.addButton(withTitle: "OK".localized)'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t export PNG", error:' \
  'showError("Couldn’t export PNG".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t export", error:' \
  'showError("Couldn’t export".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t change canvas size", error:' \
  'showError("Couldn’t change canvas size".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t resize the image", error:' \
  'showError("Couldn’t resize the image".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t trim image", error:' \
  'showError("Couldn’t trim image".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t save the project", error:' \
  'showError("Couldn’t save the project".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'showError("Couldn’t open the project", error:' \
  'showError("Couldn’t open the project".localized, error:' \
  2

patch_one Compositor/IO/ProjectController.swift \
  'showError("Open one project at a time", error:' \
  'showError("Open one project at a time".localized, error:'

patch_one Compositor/IO/ProjectController.swift \
  'sheet.title = "Export As"' \
  'sheet.title = "Export As".localized'

patch_one Compositor/IO/ProjectController.swift \
  'sheet.title = "Canvas Size"' \
  'sheet.title = "Canvas Size".localized'

patch_one Compositor/IO/ProjectController.swift \
  'sheet.title = "Image Size"' \
  'sheet.title = "Image Size".localized'

patch_one Compositor/IO/ProjectController.swift \
  'sheet.title = "Trim"' \
  'sheet.title = "Trim".localized'

patch_one Compositor/IO/ProjectController.swift \
  'sheet.title = "Grid"' \
  'sheet.title = "Grid".localized'

patch_one Compositor/IO/ProjectController.swift \
  'panel.title = "Open Project"' \
  'panel.title = "Open Project".localized'

patch_one Compositor/IO/ProjectController.swift \
  'deletingPathExtension().lastPathComponent ?? "Untitled")' \
  'deletingPathExtension().lastPathComponent ?? "Untitled".localized)'

patch_one Compositor/IO/ProjectController+ExternalChanges.swift \
  'alert.messageText = "“\(session.projectURL?.lastPathComponent ?? "Untitled")” was changed on disk."\n        alert.informativeText = "Another app changed this project. You can revert to the version on disk, losing your unsaved changes, or keep what you have."\n        alert.addButton(withTitle: "Revert")\n        alert.addButton(withTitle: "Keep Mine")' \
  'alert.messageText = String.localizedStringWithFormat(NSLocalizedString("“%@” was changed on disk.", comment: ""), session.projectURL?.lastPathComponent ?? "Untitled".localized)\n        alert.informativeText = "Another app changed this project. You can revert to the version on disk, losing your unsaved changes, or keep what you have.".localized\n        alert.addButton(withTitle: "Revert".localized)\n        alert.addButton(withTitle: "Keep Mine".localized)'

patch_one Compositor/Document/LiveLayerMask.swift \
  'alert.messageText = ids.count == 1 ? "This layer supplies a live mask" : "These layers supply live masks"\n        alert.informativeText = "Bake keeps the current masked appearance in the dependent layers’ pixels. Remove Links reveals their pixels. You can undo either choice."\n        alert.addButton(withTitle: "Bake and Delete")\n        alert.addButton(withTitle: "Cancel")\n        alert.addButton(withTitle: "Remove Links and Delete")' \
  'alert.messageText = (ids.count == 1 ? "This layer supplies a live mask" : "These layers supply live masks").localized\n        alert.informativeText = "Bake keeps the current masked appearance in the dependent layers’ pixels. Remove Links reveals their pixels. You can undo either choice.".localized\n        alert.addButton(withTitle: "Bake and Delete".localized)\n        alert.addButton(withTitle: "Cancel".localized)\n        alert.addButton(withTitle: "Remove Links and Delete".localized)'


# ==== 5.10/5.11 BEGIN ====
# --------------------------------------------------------------------------
# 5.10 菜单 / UI 标题字面量:给 Button/Menu/Toggle/Picker/Label 与
#      NSMenuItem/NSMenu(title:) 的首参补 .localized。
# 原因:SwiftUI 字面量是否走 LocalizedStringKey 在菜单(command)场景并不总可靠,
#      显式本地化最稳。只改"字面量是 strings 里已有 key"的,避免动到动态名称
#      (如最近项目名 / 图层名)。幂等:已带 .localized 或含 \( 插值的跳过。
# 编译安全:Button/Menu/Toggle/Picker/Label 均有接受 String 的重载
#      (已用 swiftc -typecheck 验证)。不含 CommandMenu:它只有 LocalizedStringKey
#      重载,传 String 会编译失败。
# --------------------------------------------------------------------------
python3 - <<'PY'
import os, re
STRINGS = "Compositor/zh-Hans.lproj/Localizable.strings"
keys = set()
for line in open(STRINGS, encoding="utf-8"):
    m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', line)
    if m:
        keys.add(m.group(1))

ctor = re.compile(r'\b(Button|Menu|Toggle|Picker|Label)\(\s*"((?:[^"\\]|\\.)*)"')
nsmenu = re.compile(r'((?:NSMenuItem|NSMenu)\(title:\s*)"((?:[^"\\]|\\.)*)"')
# ".localized" 正好 10 个字符。切片要用 len(SUFFIX) 而不是写死 10/11,
# 否则会漏掉最后一个字符而永远判不相等,于是每次运行都再叠一层 .localized。
SUFFIX = ".localized"

changed = 0
for root, _, files in os.walk("Compositor"):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        p = os.path.join(root, fn)
        txt0 = open(p, encoding="utf-8").read()
        state = {"t": txt0}

        def rc(m):
            name, lit = m.group(1), m.group(2)
            if "\\(" in lit or lit not in keys:
                return m.group(0)
            if state["t"][m.end():m.end() + len(SUFFIX)] == SUFFIX:
                return m.group(0)
            state["n"] = state.get("n", 0) + 1
            return name + '("' + lit + '"' + SUFFIX

        def rm(m):
            pre, lit = m.group(1), m.group(2)
            if "\\(" in lit or lit not in keys:
                return m.group(0)
            if state["t"][m.end():m.end() + len(SUFFIX)] == SUFFIX:
                return m.group(0)
            state["n"] = state.get("n", 0) + 1
            return pre + '"' + lit + '"' + SUFFIX

        txt1 = ctor.sub(rc, txt0)
        state["t"] = txt1
        txt2 = nsmenu.sub(rm, txt1)
        if txt2 != txt0:
            open(p, "w", encoding="utf-8").write(txt2)
            changed += state.get("n", 0)
print("5.10 localized literals: {}".format(changed))
PY

# --------------------------------------------------------------------------
# 5.11 菜单里动态拼接 / 三元表达式的标题(通用 5.10 抓不到)
# --------------------------------------------------------------------------
# 上游 PR #282 给 Undo 菜单项加了钢笔分支(penDraft / canUndoPenClosure),
# 未并入钢笔工具时无这些条件。两种源码形态都要能匹配。
if [[ -f Compositor/UI/PenControls.swift ]]; then
patch_one Compositor/CompositorApp.swift \
  'Button(session.penDraft != nil ? "Undo Add Path Point" : session.canUndoPenClosure ? "Undo Close Path" : session.history.canUndo ? "Undo \(session.history.undoName)" : "Undo") { session.undo() }' \
  'Button(session.penDraft != nil ? "Undo Add Path Point".localized : session.canUndoPenClosure ? "Undo Close Path".localized : session.history.canUndo ? String.localizedStringWithFormat(NSLocalizedString("Undo %@", comment: ""), session.history.undoName) : "Undo".localized) { session.undo() }'
else
patch_one Compositor/CompositorApp.swift \
  'Button(session.history.canUndo ? "Undo \(session.history.undoName)" : "Undo") { session.undo() }' \
  'Button(session.history.canUndo ? String.localizedStringWithFormat(NSLocalizedString("Undo %@", comment: ""), session.history.undoName) : "Undo".localized) { session.undo() }'
fi

patch_one Compositor/CompositorApp.swift \
  'Button(session.history.canRedo ? "Redo \(session.history.redoName)" : "Redo") { session.redo() }' \
  'Button(session.history.canRedo ? String.localizedStringWithFormat(NSLocalizedString("Redo %@", comment: ""), session.history.redoName) : "Redo".localized) { session.redo() }'

patch_one Compositor/CompositorApp.swift \
  'Button(session.isMaskSelected ? "Invert Mask" : "Invert") { Task { await session.invertPixels() } }' \
  'Button(session.isMaskSelected ? "Invert Mask".localized : "Invert".localized) { Task { await session.invertPixels() } }'

patch_one Compositor/CompositorApp.swift \
  'Button(session.lastFilter.map { "Last Filter: " + $0.rawValue } ?? "Last Filter") {' \
  'Button(session.lastFilter.map { String.localizedStringWithFormat(NSLocalizedString("Last Filter: %@", comment: ""), $0.localizedName) } ?? "Last Filter".localized) {'

patch_one Compositor/CompositorApp.swift \
  'Button("\(kind.rawValue)…") { session.beginFilter(kind) }' \
  'Button(kind.localizedName + "…") { session.beginFilter(kind) }' \
  2

patch_one Compositor/CompositorApp.swift \
  'Button(kind.rawValue + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }' \
  'Button(kind.localizedName + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }'

patch_one Compositor/CompositorApp.swift \
  'Button(session.canTransformSelection ? "Transform Selection" : "Transform Layer") { session.transformCommand() }' \
  'Button(session.canTransformSelection ? "Transform Selection".localized : "Transform Layer".localized) { session.transformCommand() }'

patch_one Compositor/CompositorApp.swift \
  'Button(session.selection == nil ? "Duplicate Layer" : "Layer via Copy") { session.layerViaCopy() }' \
  'Button(session.selection == nil ? "Duplicate Layer".localized : "Layer via Copy".localized) { session.layerViaCopy() }'

patch_one Compositor/CompositorApp.swift \
  'Button(session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask") {' \
  'Button(session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask".localized : "Release Clipping Mask".localized) {'

patch_one Compositor/CompositorApp.swift \
  'Button(session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer") {' \
  'Button(session.activeLayer?.isVisible == false ? "Show Layer".localized : "Hide Layer".localized) {'

patch_one Compositor/CompositorApp.swift \
  'Button(session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer") {' \
  'Button(session.selectedEffect != nil ? String.localizedStringWithFormat(NSLocalizedString("Delete %@", comment: ""), session.selectedEffect!.kind.localizedName) : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask".localized : session.selectedLayerIDs.count > 1 ? "Delete Layers".localized : "Delete Layer".localized) {'

patch_one Compositor/UI/LayersPanel.swift \
  'Button(kind.rawValue + "…") { session.addEffect(kind) }' \
  'Button(kind.localizedName + "…") { session.addEffect(kind) }'

patch_one Compositor/UI/LayersPanel.swift \
  'Button(kind.rawValue) { session.addAdjustment(kind) }' \
  'Button(kind.localizedName) { session.addAdjustment(kind) }'

patch_one Compositor/UI/LevelsSheet.swift \
  'Button(mode.rawValue) { session.autoLevels(mode) }' \
  'Button(mode.localizedName) { session.autoLevels(mode) }'

patch_one Compositor/Document/LayerMerge.swift \
  '"Merge Layers")' \
  '"Merge Layers".localized)'

patch_one Compositor/Document/LayerMerge.swift \
  '"Merge Group")' \
  '"Merge Group".localized)'

patch_one Compositor/Document/LayerMerge.swift \
  'var mergeTitle: String { mergePlan()?.action ?? "Merge Down" }' \
  'var mergeTitle: String { mergePlan()?.action.localized ?? "Merge Down".localized }' \
  2

patch_one Compositor/Document/LayerMerge.swift \
  'beginEdit(plan.action)' \
  'beginEdit(plan.action.localized)'

patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Mask"' \
  'deleteTitle = "Delete Mask".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Selected Layers"' \
  'deleteTitle = "Delete Selected Layers".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'deleteTitle = "Delete Layer"' \
  'deleteTitle = "Delete Layer".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'let clippingTitle = session.activeLayer?.maskSourceID != nil ? "Release Clipping Mask" : "Create Clipping Mask"' \
  'let clippingTitle = session.activeLayer?.maskSourceID != nil ? "Release Clipping Mask".localized : "Create Clipping Mask".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'let toggleMaskTitle = session.activeLayer?.mask?.isEnabled == false ? "Enable Mask" : "Disable Mask"' \
  'let toggleMaskTitle = session.activeLayer?.mask?.isEnabled == false ? "Enable Mask".localized : "Disable Mask".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'let linkMaskTitle = session.activeLayer?.mask?.isLinked == false ? "Link Mask" : "Unlink Mask"' \
  'let linkMaskTitle = session.activeLayer?.mask?.isLinked == false ? "Link Mask".localized : "Unlink Mask".localized'

patch_one Compositor/UI/NativeLayerList.swift \
  'let visibilityTitle = session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer"' \
  'let visibilityTitle = session.activeLayer?.isVisible == false ? "Show Layer".localized : "Hide Layer".localized'

patch_one Compositor/Document/LayerMerge.swift \
  'return ([below.id, active.id], [below.id, active.id], below.name, active.parentID, active.id, "Merge Down")' \
  'return ([below.id, active.id], [below.id, active.id], below.name, active.parentID, active.id, "Merge Down".localized)'

patch_one Compositor/CompositorApp.swift \
  'CommandMenu("Select")' \
  'CommandMenu("Select".localized)'

patch_one Compositor/CompositorApp.swift \
  'CommandMenu("Image")' \
  'CommandMenu("Image".localized)'

patch_one Compositor/CompositorApp.swift \
  'CommandMenu("Filter")' \
  'CommandMenu("Filter".localized)'

patch_one Compositor/CompositorApp.swift \
  'CommandMenu("Layer")' \
  'CommandMenu("Layer".localized)'

# ==== 5.10/5.11 END ====

# --------------------------------------------------------------------------
# 5.12 control()/slider()/swatch()/... 自定义 helper + .help() 修饰器的本地化
# 原因:FilterSheet 自带 control(_ title: String, ...) helper,
# HueSaturationSheet 自带 slider(_ title: String, ...),Camera Raw 各面板
# 有 wheel/colorSlider/pointSlider/sharpenSlider/opticsSlider/geometrySlider/
# calibrationSlider/channelRow/field/dimension 等,它们都接收 String 标题
# 并在内部用 Text(title) 渲染 —— 因为 title 是 String 不是 LocalizedStringKey,
# SwiftUI 不会自动本地化。同样,.help("...") 字符串也补 .localized 防极端。
# 安全:只对 keys 文件中存在的字面量加 .localized,动态/插值字符串跳过。
# 幂等:已加 .localized 的会跳过,重复运行安全。
# --------------------------------------------------------------------------
python3 - <<'PY'
import os, re
STRINGS = "Compositor/zh-Hans.lproj/Localizable.strings"
keys = set()
for line in open(STRINGS, encoding="utf-8"):
    m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', line)
    if m:
        keys.add(m.group(1))

# 自定义 helper 列表(都接收第一个 String 参数做 title/label)
# 新增 helper 时在这里追加,不要写具体正则,避免每次都改 regex。
HELPERS = [
    "control",          # FilterSheet.swift
    "slider",           # HueSaturationSheet / Camera Raw 各面板
    "swatch",           # FilterSheet
    "wheel",            # CameraRawColorControls
    "colorSlider",      # CameraRawColorControls
    "pointSlider",      # CameraRawColorControls (Curves)
    "sharpenSlider",    # CameraRawDetailOpticsControls
    "opticsSlider",     # CameraRawDetailOpticsControls
    "geometrySlider",   # CameraRawGeometryCalibrationControls
    "calibrationSlider",# CameraRawGeometryCalibrationControls
    "hueRange",         # CameraRawDetailOpticsControls
    "field",            # LevelsSheet
    "dimension",        # NewCanvasSheet
    "channelRow",       # ColorPickerSheet
]
helper_alt = "|".join(HELPERS)
helper_re = re.compile(rf'\b({helper_alt})\(\s*"((?:[^"\\]|\\.)*)"')
help_re   = re.compile(r'(\.help\()\s*"((?:[^"\\]|\\.)*)"')

def run(txt, pat, prefix):
    # re.sub 一次扫描完成,不会因替换扩张/收缩导致位置错位
    # prefix: 固定字符串前缀(如 ".help(");若为 None,则从 match.group(1) 取(用于 helper 名)
    n = [0]
    def cb(m):
        lit = m.group(2)
        if "\\(" in lit or lit not in keys:
            return m.group(0)
        end = m.end()
        if txt[end:end + len(".localized")].startswith(".localized"):
            return m.group(0)
        n[0] += 1
        p = prefix if prefix is not None else m.group(1) + "("
        return f'{p}"{lit}".localized'
    out = pat.sub(cb, txt)
    return out, n[0]

totals = {"helper": 0, "help": 0}
per_helper = {}
for root, _, files in os.walk("Compositor"):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        p = os.path.join(root, fn)
        txt0 = open(p, encoding="utf-8").read()
        t1, n1 = run(txt0, helper_re, None)  # prefix 由 match 决定
        t2, n2 = run(t1, help_re, ".help(")
        if t2 != txt0:
            open(p, "w", encoding="utf-8").write(t2)
            totals["helper"] += n1
            totals["help"]   += n2
print("5.12 helpers: {}   .help(): {}".format(totals["helper"], totals["help"]))
PY

# 5.13 FilterSheet 标题:filterPanel.show(title:) 用的是 kind.rawValue,
# 而 FilterKind 已通过 add_enum_name 注入了 .localizedName。把 rawValue
# 改成 localizedName,标题就会跟着 .strings 走。
patch_one Compositor/ContentView.swift \
  'filterPanel.show(title: session.filterEdit?.kind.rawValue ?? "Filter", content: FilterSheet(session: session),' \
  'filterPanel.show(title: session.filterEdit?.kind.localizedName ?? "Filter".localized, content: FilterSheet(session: session),'

# 5.14 兜底:把 FilterSheet 里"独立"的英文字面量也加上 .localized
# (例如 .scrubbable 里 help 提示参数等)。仅匹配 keys 中存在的字面量。
python3 - <<'PY'
import os, re
STRINGS = "Compositor/zh-Hans.lproj/Localizable.strings"
keys = set()
for line in open(STRINGS, encoding="utf-8"):
    m = re.match(r'\s*"((?:[^"\\]|\\.)*)"\s*=', line)
    if m:
        keys.add(m.group(1))

# 匹配 "title" : "(...)" / title="(...)" / title = "(...)" / Text("...")
# 仅当字面量在 keys 且未被 .localized 包裹时,加 .localized。
# 不动 Text("...") 因为它走 LocalizedStringKey 自动本地化,加 .localized 会改变类型。
patterns = [
    # filterPanel.show(title: "...", ...)
    (re.compile(r'(filterPanel\.show\(title:\s*)"((?:[^"\\]|\\.)*)"'), 'filterPanel.show(title: '),
    # alert.title / alert.messageText / alert.informativeText 已被 5.9 处理;这里只补漏
    (re.compile(r'(sheet\.title\s*=\s*)"((?:[^"\\]|\\.)*)"'), 'sheet.title = '),
    (re.compile(r'(panel\.title\s*=\s*)"((?:[^"\\]|\\.)*)"'), 'panel.title = '),
]

def run(txt, pat, prefix):
    # re.sub 一次扫描完成,不会因替换扩张/收缩导致位置错位
    n = [0]
    def cb(m):
        lit = m.group(2)
        if "\\(" in lit or lit not in keys:
            return m.group(0)
        end = m.end()
        if txt[end:end + len(".localized")].startswith(".localized"):
            return m.group(0)
        n[0] += 1
        return f'{prefix}"{lit}".localized'
    out = pat.sub(cb, txt)
    return out, n[0]

totals = 0
for root, _, files in os.walk("Compositor"):
    for fn in files:
        if not fn.endswith(".swift"):
            continue
        p = os.path.join(root, fn)
        txt0 = open(p, encoding="utf-8").read()
        t = txt0
        for pat, prefix in patterns:
            t, n = run(t, pat, prefix)
            totals += n
        if t != txt0:
            open(p, "w", encoding="utf-8").write(t)
print(f"5.14 sheet/panel titles + filterPanel.show: {totals}")
PY

# --------------------------------------------------------------------------
# 5.15 面板硬编码标题 (Levels / Color Range / Hue/Saturation)
# 这些是 ContentView 里 hardcoded 的字面量,不走 enum.rawValue,需单独补丁。
# --------------------------------------------------------------------------
patch_one Compositor/ContentView.swift \
  'adjustmentPanel.show(title: "Hue/Saturation", content: HueSaturationSheet(session: session))' \
  'adjustmentPanel.show(title: "Hue/Saturation".localized, content: HueSaturationSheet(session: session))'

patch_one Compositor/ContentView.swift \
  'levelsPanel.show(title: "Levels", content: LevelsSheet(session: session))' \
  'levelsPanel.show(title: "Levels".localized, content: LevelsSheet(session: session))'

patch_one Compositor/ContentView.swift \
  'colorRangePanel.show(title: "Color Range", content: ColorRangeSheet(session: session))' \
  'colorRangePanel.show(title: "Color Range".localized, content: ColorRangeSheet(session: session))'

# --------------------------------------------------------------------------
# 5.16 AdjustmentKind.rawValue / LayerEffectKind.rawValue 在关键位置
# 应替换为 .localizedName(由 5.3 add_enum_name 注入)
# 包括:
#   - 调整图层默认名 (LayerAdjustment.swift)
#   - 图层效果默认名 (LayerEffects.swift)
#   - 编辑历史名 (LayerAdjustment / AdjustmentEditing / LayerEffects)
#   - 图层面板显示 (NativeLayerList.swift)
# --------------------------------------------------------------------------
patch_one Compositor/Document/LayerAdjustment.swift \
  'var layer = ImageLayer(name: kind.rawValue, blankSize: document.size)' \
  'var layer = ImageLayer(name: kind.localizedName, blankSize: document.size)'

patch_one Compositor/Document/LayerAdjustment.swift \
  'beginEdit("New \(kind.rawValue) Adjustment")' \
  'beginEdit("New \(kind.localizedName) Adjustment")'

patch_one Compositor/Document/AdjustmentEditing.swift \
  'beginEdit("Edit \(original.kind.rawValue) Adjustment")' \
  'beginEdit("Edit \(original.kind.localizedName) Adjustment")'

# LayerEffect 历史名(Add / Cancel / Edit / Copy / Hide / Show / Remove)
patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: id, name: "Add " + kind.rawValue)' \
  'setEffects(effects, on: id, name: "Add " + kind.localizedName)'

patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: editing.layerID, name: "Cancel " + editing.kind.rawValue)' \
  'setEffects(effects, on: editing.layerID, name: "Cancel " + editing.kind.localizedName)'

patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: layer.id, name: "Edit " + editing.kind.rawValue)' \
  'setEffects(effects, on: layer.id, name: "Edit " + editing.kind.localizedName)'

patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: target, name: "Copy " + kind.rawValue)' \
  'setEffects(effects, on: target, name: "Copy " + kind.localizedName)'

patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: id, name: (enabled ? "Hide " : "Show ") + kind.rawValue)' \
  'setEffects(effects, on: id, name: (enabled ? "Hide " : "Show ") + kind.localizedName)'

patch_one Compositor/Document/LayerEffects.swift \
  'setEffects(effects, on: selectedEffect.layerID, name: "Remove " + selectedEffect.kind.rawValue)' \
  'setEffects(effects, on: selectedEffect.layerID, name: "Remove " + selectedEffect.kind.localizedName)'

# 图层面板行的 kind 显示(LayerEffectKind 与 AdjustmentKind 都用 .localizedName)
patch_one Compositor/UI/NativeLayerList.swift \
  'label = NSTextField(labelWithString: kind.rawValue)' \
  'label = NSTextField(labelWithString: kind.localizedName)'

# AdjustmentLayer 缩略图 accessibility description
patch_one Compositor/UI/NativeLayerList.swift \
  'thumbnail.image = layer.adjustment.map { Self.adjustmentIcon($0.kind.symbol, description: $0.kind.rawValue, quarterTurnClockwise: $0.kind == .curves) }' \
  'thumbnail.image = layer.adjustment.map { Self.adjustmentIcon($0.kind.symbol, description: $0.kind.localizedName, quarterTurnClockwise: $0.kind == .curves) }'

# 眼睛按钮的辅助标签(Show/Hide X)
patch_one Compositor/UI/NativeLayerList.swift \
  'eye.setAccessibilityLabel((enabled ? "Hide " : "Show ") + kind.rawValue)' \
  'eye.setAccessibilityLabel((enabled ? "Hide " : "Show ") + kind.localizedName)'

# 行的 toolTip
patch_one Compositor/UI/NativeLayerList.swift \
  'toolTip = "Click to select; double-click to edit; Option-drag to copy " + kind.rawValue.lowercased()' \
  'toolTip = "Click to select; double-click to edit; Option-drag to copy " + kind.localizedName.lowercased()'

# --------------------------------------------------------------------------
# 5.17 上游新增界面的收口补丁
# 5.10/5.12/5.14 的通用规则只认「首参是字面量」的 Button/Text/.help()/helper。
# 下面几处英文仍在界面上,但都逃过了那些规则,逐条点名补:
#   - panel.message = "…":NSOpenPanel 的 message 是 String 属性,没有
#     LocalizedStringKey 重载,5.14 只处理 sheet.title / panel.title。
#   - Menu(chosen ? a : b):首参是三元表达式,ctor 正则要求 Button(/Text( 后紧跟
#     引号,匹配不到;而三元里两边都得本地化。
#   - Text(cap.rawValue) / accessibilityLabel(style.rawValue):rawValue 是运行时
#     String,不走 LocalizedStringKey。改用 5.3 注入的 .localizedName。
#   - Text(definition.title) / Text(group):SwiftUI 按 String 渲染,同样不本地化。
#     definition.title 还同时被 .localizedCaseInsensitiveContains 搜索,所以
#     显示和搜索都用本地化名才一致。
# --------------------------------------------------------------------------

# NSOpenPanel.message(CMYK 配置文件,View › CMYK 与导出面板各一处)
patch_one Compositor/CompositorApp.swift \
  'panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you"' \
  'panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you".localized'
patch_one Compositor/UI/ExportAsSheet.swift \
  'panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you"' \
  'panel.message = "Choose a CMYK ICC profile, such as the one your printer gave you".localized'

# 导出「更多格式」菜单:标题是三元表达式,分支两边都要本地化
patch_one Compositor/UI/ExportAsSheet.swift \
  'let menu = Menu(chosen ? format.rawValue : "More") {' \
  'let menu = Menu(chosen ? format.rawValue : "More".localized) {'

# 形状线条:样式/端点拾取器用枚举的 .localizedName(5.3 已注入)
patch_one Compositor/UI/ShapeControls.swift \
  'Image(nsImage: LineSample.style(style)).accessibilityLabel(style.rawValue).tag(style)' \
  'Image(nsImage: LineSample.style(style)).accessibilityLabel(style.localizedName).tag(style)'
patch_one Compositor/UI/ShapeControls.swift \
  'Label { Text(cap.rawValue) } icon: { Image(nsImage: LineSample.cap(cap)) }.tag(cap)' \
  'Label { Text(cap.localizedName) } icon: { Image(nsImage: LineSample.cap(cap)) }.tag(cap)'

# 快捷键面板:分组标题与条目名都是运行时 String
patch_one Compositor/UI/KeyboardShortcuts.swift \
  'ForEach(["Menus", "Canvas & Layers", "Text Editing"], id: \.self) { group in
                        Text(group).font(.headline).padding(.top, 8)' \
  'ForEach(["Menus", "Canvas & Layers", "Text Editing"], id: \.self) { group in
                        Text(group.localized).font(.headline).padding(.top, 8)'
patch_one Compositor/UI/KeyboardShortcuts.swift \
  'Text(definition.title)' \
  'Text(definition.title.localized)'

say "所有 Swift 补丁应用完成"

# --------------------------------------------------------------------------
# 6. 校验 strings
# --------------------------------------------------------------------------
python3 - "$STRINGS_FILE" <<'PY'
import re, sys
from collections import defaultdict
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
lines = [l.strip() for l in txt.splitlines() if l.strip() and not l.strip().startswith("/*")]
bad = [l for l in lines if not re.fullmatch(r'"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', l)]
d = defaultdict(set)
for l in lines:
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', l)
    if m:
        d[m.group(1)].add(m.group(2))
print(f"OK strings unique={len(d)} bad={len(bad)}")
if bad:
    for b in bad[:3]: print("BAD:", b)
    sys.exit(1)
PY

# --------------------------------------------------------------------------
# 7. 提交 + 推送
# --------------------------------------------------------------------------
git add -A
if ! git diff --cached --quiet; then
  git commit -m "Localize Compositor into Simplified Chinese (zh-Hans)"
  if [[ "${SKIP_PUSH:-0}" == "1" ]]; then
    say "已提交,跳过推送 (SKIP_PUSH=1)"
  else
    if [[ -z "${GH_TOKEN:-}" ]]; then
      warn "GH_TOKEN 未设置,跳过推送"
    else
      git push "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "HEAD:refs/heads/${BRANCH}" && \
        say "已推送到 ${REPO}:${BRANCH}"
    fi
  fi
else
  say "无变更需要提交(项目已是最新)"
fi

# --------------------------------------------------------------------------
# 8. 触发 Build x86_64
# --------------------------------------------------------------------------
if [[ "${SKIP_TRIGGER:-0}" == "1" ]]; then
  say "SKIP_TRIGGER=1,跳过 Build x86_64 工作流触发"
else
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh workflow run "Build x86_64" --repo "$REPO" --ref "$BRANCH" && \
      say "已触发 Build x86_64 工作流"
  else
    warn "gh CLI 未登录,跳过(请手动到 Actions 页面 Run workflow)"
  fi
fi

say "全部完成 ✓"