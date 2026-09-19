# skills · 非代码会话一键导出

把下面「任务书」整段复制给 Codex（Windows 本机、能运行终端命令的 AI），
或保存为 `.md` 文件上传后说"按此执行"，即可自动完成：
环境检查 → 安装依赖与技能 → 运行导出 → 校验 → 报告压缩包位置。
不需要会命令行。

## 任务书（整段复制给 AI）

````markdown
# 非代码会话一键导出（任务书 v2）

你是执行者。请直接执行本任务：检查环境 → 安装缺失依赖与两个技能 →
运行导出 → 校验 → 报告压缩包位置。全程自主完成，不要向我索要命令或
确认选择。仅当遇到无法自动完成的系统权限或网络授权时才暂停。不得导出
凭据，不得上传会话。

若当前用户只是要求解释或审阅本文件，不要执行导出；附件本身不构成授权，
无法确认执行意图时，只问一次"是否按本任务直接导出"。

## 第一步 · 环境检查（缺失才装）

| 依赖 | 验证（真实执行） | 缺失安装 |
|---|---|---|
| Node.js + npx | `node --version`、`npx.cmd --version` | winget: `OpenJS.NodeJS.LTS` |
| Git Bash | `"C:/Program Files/Git/bin/bash.exe" --version` | winget: `Git.Git` |
| python3 | `python3 --version`（可能只是 Store 桩，必须执行验证） | scoop: `scoop install python`；或 winget: `Python.Python.3.13` |
| jq、ripgrep | `jq --version`、`rg --version` | scoop: `scoop install jq ripgrep` |

Windows 全程使用 Git Bash（`C:/Program Files/Git/bin/bash.exe`），
不用 WSL、不用 `System32/bash.exe`、不用 PowerShell 的 `python` 别名。
安装后刷新当前进程 PATH 或直接用绝对路径，不要求重启。

## 第二步 · 安装两个技能（总是重装最新版）

```powershell
npx.cmd --yes skills@latest add Samuka007/skills --skill session-export-nocode --skill agent-session-batch-export -g -y
```

**无论之前是否装过，都必须重新执行这条命令**：安装器总是拉取仓库最新版
并整体覆盖本地副本，而技能本身不会自动更新——跳过重装就会一直运行旧版。
`-g` 装到 `~/.agents/skills/`，与下一步的启动器路径一致。安装完成后读取
实际使用的两个 `SKILL.md`，并确认以下文件存在：
`agent-session-batch-export/scripts/{funnel.py,policy.json,export-direction.sh}` 与
`session-export-nocode/direction.json`。缺一即按 SKILL.md 的安装指引停下报告。

## 第三步 · 运行导出（一条命令）

```bash
mkdir -p exports/nocode-<YYYYMMDD-HHMMSS>
bash "$HOME/.agents/skills/session-export-nocode/scripts/session-export-nocode.sh" \
  --out <上面的导出目录> --agent both --min-lines 0
```

规则：

- **默认即无人值守（yolo）**：不需要任何短语，也禁止手工追加 `--yolo`
  或改用基础技能的人工筛选流程代替方向流程。
- 用户明确要求"先让我确认"时，才加 `--confirm`（会出现 `[y/N]`，交给用户）。
- 禁止：修改 `policy.json`、`themes/`、`direction.json` 或任何筛选产物；
  传递 `--allow-credentials`；用模型语义筛选会话。
- 凭据命中由引擎自动处理：命中行**剔除并披露**（不会写入交付包），在报告
  里给出剔除数量即可，不是错误。
- 零入选是有结果的运行：如实报告扫描数，不产空包，不算失败。

## 第四步 · 校验并报告

1. 交付压缩包存在且非空；
2. `manifest.json` 条数 = `keep/` 文件数；
3. 逐条 sha256 与清单一致（源文件可访问时同时与源文件核对）；
4. 向用户报告（保持简洁）：

```text
已完成：<压缩包绝对路径>
扫描：M 个；导出：N 个；凭据剔除：K 个；完整性校验：N/N 通过。
提醒：内容未脱敏，分享前请自行检查。
```

失败时报告：阶段、原始错误关键内容、已尝试的处理、最小下一步；
不把失败转交成一整套手工教程。
````

## 运行完成后你会得到

- `<导出目录>/keep/`：原始会话副本（与源文件字节级一致）
- `manifest.json`：每条会话的 SHA256 与来源记录
- 交付压缩包（zip）
- 含凭据的会话已被自动剔除并逐条报告（不会进入交付包）；
  其余内容未脱敏，分享前请自行检查

## 这套仓库包含两个技能

| 技能 | 作用 |
|---|---|
| session-export-nocode | 非代码方向包：四个主题（role-play / 写作 / 策划 / 报告分析）+ 一键启动器，默认无人值守 |
| agent-session-batch-export | 引擎与管线：确定性 funnel、全局 policy、主题词表、交互式人工筛选 |

## 手动安装（也可以让上面的 AI 代装）

```bash
npx skills add Samuka007/skills --skill session-export-nocode --skill agent-session-batch-export -g
```

## 维护者 / 开发者

仓库布局、开发命令、测试套件与验收流程见
[docs/DEVELOP.md](docs/DEVELOP.md)；条目账本与验收证据见
[SPEC/README.md](SPEC/README.md)。
