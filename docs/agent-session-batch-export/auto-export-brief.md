# 非代码会话一键导出（任务书 v2 · 简洁版）

把本文件粘贴给 Codex（Windows 本机、可执行终端命令），或作为附件上传后
明确说"按此执行"。本文件是给 AI 的执行指令，不是教程；不要重写或展开它。

## 执行请求

> 请直接执行本任务：检查环境 → 安装缺失依赖与两个技能 → 运行导出 → 校验
> → 报告压缩包位置。全程自主完成，不要向我索要命令或确认选择。仅当遇到
> 无法自动完成的系统权限或网络授权时才暂停。不得导出凭据，不得上传会话。

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

## 第二步 · 安装两个技能

```powershell
npx.cmd --yes skills@latest add Samuka007/skills --skill session-export-nocode --skill agent-session-batch-export --agent codex -y
```

安装后读取实际使用的两个 `SKILL.md`，并确认以下文件存在：
`agent-session-batch-export/scripts/{funnel.py,policy.json,export-direction.sh}` 与
`session-export-nocode/direction.json`。缺一即按 SKILL.md 的安装指引停下报告。

## 第三步 · 运行导出（一条命令）

```bash
mkdir -p exports/nocode-<YYYYMMDD-HHMMSS>
bash "$HOME/.agents/skills/session-export-nocode/scripts/session-export-nocode.sh" \
  --out <上面的导出目录> --agent both --min-lines 0
```

规则：

- **新版默认即无人值守（yolo）**：不需要任何短语，也禁止手工追加 `--yolo`
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
