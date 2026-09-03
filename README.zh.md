[🇺🇸English](README.md) · **🇨🇳中文**

# claude-code-discord-multibot

让 Claude Code 每个项目目录绑定一个独立的 Discord bot · 互不干扰 · 切项目只需在 Discord 切频道 · 支持上百个 bot 规模

> **姐妹仓库:** [`claude-code-telegram-multibot`](https://github.com/Lihan-Zhong/claude-code-telegram-multibot) —— 同样架构的 Telegram 版本。如果你撞上了 Telegram @BotFather 的 20 bot 上限，或者想用 Discord 独家功能（`fetch_messages` 消息历史、双向 reactions 等），就用本仓库。

> **太长不看版** —— 把官方 `[discord` 插件](https://github.com/anthropics/claude-plugins-official) 配上几个 shell 函数和一份 Claude Code skill，让每个项目目录拥有自己的 Discord bot。切项目只需在 Discord 里换频道，不再需要切终端。姐妹项目 `[claude-code-telegram-multibot](https://github.com/Lihan-Zhong/claude-code-telegram-multibot)` —— 同样的架构，换平台部署。
>
> 当你撞上 Telegram 的 20 bot 上限，或者想要更丰富的功能（消息历史查询 `fetch_messages`、双向 reaction、threads、channel 树状组织）时，用这个 Discord 版本。

## ✨ 为什么需要它

官方 Discord 插件默认是 **一用户一 bot**。如果你想让多个 Claude Code 项目各对接一个 Discord 频道，会撞上两堵墙：

- 每次 `claude` 启动都会拉起插件的 MCP server，默认共享 state 目录，新会话会扰乱前一个
- `/discord:access` skill 硬编码默认的 state 目录路径，所以"每项目一个 pair 流程"在那里走不通

关键发现：插件的 `server.ts` 尊重 `DISCORD_STATE_DIR` 环境变量。给每个项目指定不同的目录，就得到完整隔离 —— 独立 token、独立 pairing、独立 bot server，互不打架。

`claude-dc.bash` 里的 shell 函数会根据 `basename "$PWD"` 自动派生 `DISCORD_STATE_DIR`，所以在任何项目目录里跑 `claude-dc` 自动对接那个项目的 bot。配套的 `SKILL.md` 让 Claude Code agent 懂这套架构，于是 *"给这个项目加个新 Discord bot"* 变成一句话搞定。

这个 skill 当然不止可以用于 **Claude Code**，它也可以直接迁移到 Codex / OpenClaw 等其它 agent 平台。同理，这个思路也不止可以用于 **Discord**，Telegram（姐妹仓库）/ Slack / IRC / Matrix / iMessage / ... 任何一个平台只要采用 "per-token + per-channel" 的 bot 模型都能用。

## 🚀 快速开始

> 前置条件：已装 Claude Code · 官方 `discord` 插件已启用 · `bun` 在 `$PATH` · 组织策略允许 `discord` channel plugin（admin 需把它加进 `allowedChannelPlugins`）· 有 Discord 账号和你自己的 Discord server。

```bash
# 1. 安装
git clone https://github.com/Lihan-Zhong/claude-code-discord-multibot.git
cd claude-code-discord-multibot

# 2. 加载 shell 函数
echo "source $PWD/claude-dc.bash" >> ~/.bashrc
source ~/.bashrc

# 3. 安装 skill（让 Claude Code agent 懂这套架构）
mkdir -p ~/.claude/skills/setup-discord-multibot
cp SKILL.md ~/.claude/skills/setup-discord-multibot/SKILL.md

# 4. 可选但强烈建议：插件补丁 + 两个钩子（见下面「机制层」）
cp patch-discord-plugin.sh ~/.claude/ && chmod +x ~/.claude/patch-discord-plugin.sh
mkdir -p ~/.claude/hooks && cp hooks/*.py ~/.claude/hooks/
~/.claude/patch-discord-plugin.sh          # 幂等，随时可重跑
```

> ⚠️ 钩子必须注册在 **`~/.claude/settings.json`**，不能放 `settings.local.json` ——
> 原因见下面的[机制层](#-机制层钩子--插件补丁)。

给某个项目加一个 bot：

```bash
cd /path/to/my-project           # 任意项目

# 在 https://discord.com/developers/applications 操作：
#   1. New Application → 起名
#   2. Bot 标签 → Reset Token → 复制
#   3. 开启 Message Content Intent
#   4. OAuth2 → URL Generator → scope: bot + 权限 → 邀请到你的 server

claude-dc-init                   # 粘贴 token，写入 .env
claude-dc                        # 启动 Claude Code，并挂上这个 bot

# 在 Discord 里：给新 bot 发任意普通消息（比如 hi）
# bot 会回一个 6 位的 pair 码
claude-dc-pair <6位码>           # 如果装了 jq
# 或在 Claude Code 会话里说："我拿到 pair 码了，帮我配对一下"
```

完成。以后 `cd /path/to/my-project && claude-dc` 自动接到同一个 bot。

## 🚀 更简单的快速开始

```bash
# 1. 安装
git clone https://github.com/Lihan-Zhong/claude-code-discord-multibot.git
cd claude-code-discord-multibot
```

然后，打开 Claude Code，让它直接读整个仓库并按 `SKILL.md` 流程走。一看就明白 🔥

## ‼️ 推荐的使用用法

- 第一步：先给 `$HOME` 目录部署 **第一个 Discord bot** —— 连接你的"主管" Claude Code 终端
- 第二步：用刚刚的"主管" bot 来帮你部署后续的项目 bot（主管自动处理 state dir / .env / pair）
- 然后：你就有源源不断的项目专属 Discord bot，每个住在自己的 channel 或 DM 里，切换很方便

## 📁 仓库内容

- **`claude-dc.bash`** —— 六个 shell 函数：`claude-dc`、`claude-dc-init`、`claude-dc-alt`、`claude-dc-pair`，以及会判断 session 归属的 `claude-dc-resume` / `claude-dc-alt-resume`。从 `~/.bashrc` source。
- **`patch-discord-plugin.sh`** —— 对插件 `server.ts` 的三个幂等补丁：bot 之间能互相看到消息、真实的在线状态、markdown 安全的消息切分。可重复运行，插件升级后会自愈。
- **`hooks/enforce-discord-reply.py`** —— `Stop` 钩子。由 Discord 触发的回合，没往 Discord 回复就不许结束。
- **`hooks/guard-variant-memory.py`** —— `PreToolUse` 钩子。alt bot 不能写进别的 bot 的记忆命名空间。
- **`SKILL.md`** —— Claude Code skill，教 agent 掌握这套架构。放到 `~/.claude/skills/setup-discord-multibot/SKILL.md`。
- **`README.md`** / **`README.zh.md`** —— 本文件的英文/中文版。
- **`CHANGELOG.md`** —— 版本之间改了什么。
- **`LICENSE`** —— MIT。
- **`.gitignore`** —— 默认排除 token 和 state 目录，避免误提交。

## 🧩 同一项目下开两个 bot（alt 模式）

想在同一项目里跑两个独立 Claude Code 会话 —— 一个"主线"，一个"我换个思路试试"的实验？用 `claude-dc-alt`：

```bash
cd /path/to/my-project

# 主 bot 配好之后：
mkdir -p ~/.claude-discord/$(basename "$PWD")-2
$EDITOR ~/.claude-discord/$(basename "$PWD")-2/.env   # 粘第二个 bot 的 token

claude-dc-alt        # 默认变体 2
claude-dc-alt 3      # 想要第三个 bot 就用 3
```

`claude-dc-alt` 还会注入 `CLAUDE_BOT_VARIANT=N` 环境变量，让项目规则可以按变体选不同沙盒目录：

```bash
# 写在 CLAUDE.md 或项目规则文档里
SANDBOX="Intermediate_data/for_claude${CLAUDE_BOT_VARIANT:+_${CLAUDE_BOT_VARIANT}}"
```

主 bot 写到 `Intermediate_data/for_claude/`，alt bot 写到 `Intermediate_data/for_claude_2/`。互不覆盖。

### 恢复到正确的那个 session

Claude Code 的 session **只按工作目录索引** —— 没有任何东西把 session 和 `DISCORD_STATE_DIR` 绑在一起。所以同一目录下有两只 bot 时，`-c` 会挑「最近的那个」，等于抛硬币；`-r` 的选择器把两个都列出来，却不告诉你哪个是哪个。两个辅助函数替你做归属判断：

```bash
claude-dc-resume         # 恢复主 bot 自己的 session
claude-dc-alt-resume 2   # 恢复 alt 2 自己的 session
claude-dc-resume <sid>   # 逃生口：直接指定 session id
```

两者用的判据**不一样**，而这个差别才是重点。alt 好办：数每份 transcript 引用 `memory/variant_<N>/`（它自己的命名空间）的次数就行。主 bot 不能简单反过来判 —— 它的 transcript 里 `variant_2` 出现得也不少，因为你就是在它里面讨论 alt 的。真正能区分的是**这些提及出现在什么位置**：只给 session 的**开头**打分，那部分是 harness 注入的内容，不是后面聊出来的。在一个真实的五 session 目录上，按全文打分完全分不开，按开头打分则是主 bot 0 分、每个 alt 3～4 分。

两个函数都不瞎猜：没有明确归属时就新开，并且告诉你。

## 🛡️ 机制层（钩子 + 插件补丁）

v1 交付的是**约定**。约定的问题在于：它恰好在最需要的时候失效 —— 长 tool 链的末尾、压力最大的时候。v2 把其中重要的几条沉到 harness 里。

| | 做什么 | 形态 |
|---|---|---|
| `hooks/enforce-discord-reply.py` | `Stop` 钩子 —— 由 Discord 触发、却没调用 `reply`/`react`/`edit_message` 的回合，不许结束 | **拦截** |
| `hooks/guard-variant-memory.py` | `PreToolUse` 钩子 —— 拒绝写入任何不属于本 alt 的 `memory/variant_N/` 之外的记忆命名空间 | **拦截** |
| `patch-discord-plugin.sh` #1 | 让同一频道里的 bot 能看见彼此的消息（只丢弃自己的回声） | 变换 |
| `patch-discord-plugin.sh` #2 | 真实的在线状态，绿点等于「真的连着」 | 变换 |
| `patch-discord-plugin.sh` #3 | markdown 安全的 2000 字符切分 —— 代码块不会被劈成两半 | **变换** |

**能做成变换的，就别做成拦截。** 拦截仍然会产生一个「被拦了」的事件，需要有人看见、有人处理；变换没有失败事件可报，对的东西直接就出来了 —— 没人需要知道那个 chunker 存在。

两个钩子都是 **fail-open**：输入异常、工具不认识、transcript 找不到、内部报错 —— 一律放行。一个会卡死每个 session 的守卫，比它要防的那个失误更糟。

### ⚠️ 钩子只从 `~/.claude/settings.json` 加载

这条让我们白丢了两周，而且**没有任何报错和警告**。Claude Code 的 settings 加载链是：

```
<project>/.claude/settings.local.json → <project>/.claude/settings.json → ~/.claude/settings.json
```

**`~/.claude/settings.local.json` 不在这条链上。** 放在那里的 `hooks` 段会被静默忽略。正确写法：

```jsonc
// ~/.claude/settings.json
{
  "hooks": {
    "Stop": [
      { "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/hooks/enforce-discord-reply.py" }] }
    ],
    "PreToolUse": [
      { "matcher": "Write|Edit|NotebookEdit|Bash",
        "hooks": [{ "type": "command", "command": "/usr/bin/python3 $HOME/.claude/hooks/guard-variant-memory.py" }] }
    ]
  }
}
```

**另外：别用「项目目录就是 `$HOME`」的那只 bot 去验证这件事。** 对它来说 `~/.claude/settings.local.json` 恰好**就是**项目级配置文件，是链上第一个 —— 所以只在它那里生效，别处都不生效。这正是这个 bug 藏了两周的原因。要验证就去真正的项目 bot 里验。

### 怎么让补丁活下去

`patch-discord-plugin.sh` 改的是插件自己的文件，插件一升级就会被覆盖。这件事是处理过的，但值得知道是怎么处理的：

- 启动器在每次开 shell 时调一遍脚本；脚本幂等，没必要打的时候就是空转。
- 真正在跑的插件加载的是 **cache 那份**（`~/.claude/plugins/cache/.../discord/<版本号>/server.ts`），按版本号钉死。升级会生成新的版本目录，而补丁目标是通配符，所以覆盖得到。
- 如果上游把 `chunk()` 整个改名，脚本会打印 `[warn]` 并**原样不动**，而不是写出一个坏文件。补丁 #3 还会额外跑一次转译检查，结果不合法就自动回滚。
- 再加一道保险：给每个 bot 的 `access.json` 写上 `"chunkMode": "newline"`。补丁在的时候它不起作用；补丁完全没了的时候，它保证你至少还是按行切，而不是硬 `slice(0, 2000)`。

**已经在跑的 bot 不会吃到新补丁**，必须重启。

## 🤖 多 bot 协同（Discord 独家优势）

跟 Telegram 不同，Discord 允许多个 bot 共享一个 channel 并看到彼此的消息。这开启了"几个 agent 在同一个房间里协作"的玩法 —— 比如 `@planner_bot` / `@coder_bot` / `@reviewer_bot` 都在一个 channel 里，通过 @mention 协调。

权衡：bot 在共享 channel 里即便不响应也会**收到所有消息**作为 `<channel>` 事件，session 上下文会膨胀。推荐模式：日常工作让 bot 各自在隔离的 channel 里，需要真正的 cross-bot 协作时**临时建一个 "war room" channel**，协作完 archive 掉。

详见 `SKILL.md` "Multi-bot collaboration via shared channels" 章节。

## 🗂️ State 目录结构

```
~/.claude-discord/
├── <项目-A-basename>/
│   ├── .env                   # DISCORD_BOT_TOKEN=...   (chmod 600)
│   ├── access.json            # dmPolicy / allowFrom / pending (chmod 600)
│   ├── approved/<senderId>    # 配对确认信号文件（内容: chatId）
│   └── inbox/                 # 收到的附件（图片等）
├── <项目-A-basename>-2/       # 项目 A 的 alt bot
└── <项目-B-basename>/
    └── ...
```

## 🐛 已知问题

> 完整排查清单见 [`SKILL.md`](SKILL.md)。

- **注册了的钩子从来不触发。** 八成是放进了 `~/.claude/settings.local.json` —— 那个文件**不在** settings 加载链上。把 `hooks` 段搬到 `~/.claude/settings.json`。这件事没有任何报错。详见[机制层](#-机制层钩子--插件补丁)。
- **从项目子目录启动时插件不加载。** Claude Code 2.1.181 起，插件必须装在 **user scope** —— project scope 不再向子目录继承。用 `claude plugin list | grep -A2 discord` 检查，`Scope:` 必须是 `user`。症状：启动横幅提到 channels，但 `/mcp` 里没有 discord，插件子进程根本没被拉起来。
- **某个 bot 的记忆落到了别的项目的桶里。** `$HOME` 下有一个损坏或空的 `.git`（哪怕 `git` 自己都不认）就足以让 harness 的 project root 上溯停在那儿，于是所有自己没有 `.git` 的 bot 都把 project root 解析成了 `$HOME`。而 transcript 仍然按工作目录存 —— 这正是它难被发现的原因。删掉那个多余的 `.git`；完整的排查与归位流程在 `SKILL.md` 里，包括**为什么只按记忆文件名匹配不能作为作者证据**。
- **长回复被从代码块中间切开。** 那是上游 `chunk()` 在做无脑 `slice(0, 2000)`。打上 `patch-discord-plugin.sh`（补丁 #3）。注意：只把 `chunkMode` 改成 `'newline'` **治不好** —— 代码块里全是换行，它照样切在块内。
- **入站消息到不了 agent（单向通信）。** 最常见原因：组织策略没把 `discord` 加进 `allowedChannelPlugins`。Admin 必须通过 Claude.ai 管理员控制台 → Claude Code → Channels 添加。本地编辑 `~/.claude/remote-settings.json` 没用，服务器 1 小时内会覆盖回去。
- **`/discord:access pair` 报 "code not found"。** 官方 skill 硬编码默认的 state 目录路径，不尊重 `DISCORD_STATE_DIR`。改用本仓库的 `claude-dc-pair`，或按 SKILL.md 走手动文件编辑流程。
- **MCP "failed — Skipping connection" 被缓存。** 在 Claude Code 里跑 `/doctor` 然后 `/mcp`，`/mcp` 提供手动重试。别去调大 `MCP_TIMEOUT`：延长等待只在「本来就快连上了」的情况下有用；本来就连不上的时候，你只是把一个**快速失败换成了缓慢失败** —— 实测表现为启动卡满整个超时、连 Ctrl-C 都难打断。
- **Discord bot 看不到消息内容。** 去 Developer Portal → Bot → Privileged Gateway Intents 开启 "Message Content Intent"。
- **会话中途 `stop_reason: refusal`。** Anthropic 安全分类器对体积过大的 session 可能假阳性。恢复方法：`/exit` 后用 `claude-dc`（**不带 `-c`/`-r`**，否则会复活被污染的 session），通过读文件重建上下文。预防：单次 tool 输出控制在小尺寸（`head -5` 而不是 `cat`），大结果落到文件里、引用路径而不是粘贴内容。

## 🔒 安全提示

- Bot token 等同密码。`.env` 文件 `chmod 600`，外层目录 `chmod 700`。不要提交到 git，不要在群聊里粘贴。仓库的 `.gitignore` 已默认排除 `.env`、`*.env`、`.claude-discord/`、`.claude/channels/`。
- `allowFrom` 是 bot 背后 Claude Code 会话的唯一访问门槛。任何在列表里的 Discord snowflake ID 实际上可以"打字"进那个会话。把它当 shell 权限对待。
- 插件只对 `discord.com/api/v10` 和 `gateway.discord.gg` 发出站请求，没有第三方 endpoint。
- 注意 Developer Portal 里的 "Public Bot" 开关 —— 如果开着，任何拿到你 OAuth URL 的人都可以把这个 bot 装进他们自己的 server。保护好 URL。

## 🆚 vs Telegram 姐妹仓库


| 维度          | [Telegram 姐妹版](https://github.com/Lihan-Zhong/claude-code-telegram-multibot) | 本仓库（Discord）                   |
| ----------- | ---------------------------------------------------------------------------- | ------------------------------ |
| 硬性 bot 上限   | 20 个/@BotFather 账号                                                           | 实质无限                           |
| 新 bot 部署    | @BotFather 3 步（约 2 分钟）                                                       | Developer Portal 约 6 步（约 5 分钟） |
| Markdown 格式 | MarkdownV2，需大量 escape                                                        | Discord Markdown，几乎不用 escape   |
| 标题 (`# H1`) | 不支持                                                                          | 支持                             |
| 消息历史 API    | 不可用（Bot API 限制）                                                              | `fetch_messages` 工具            |
| Reactions   | 只能 bot → user                                                                | 双向（用户的 reaction bot 看得见）       |
| 多 bot 同房协作  | 不支持（只能私聊 DM）                                                                 | 支持（共享 channel）                 |
| 移动端通知       | 最快                                                                           | 略慢                             |


如果你 bot 数量少（< 20）且偏好 @BotFather 那种 in-app 简洁体验，用 Telegram 姐妹版。规模上来了（50+）或想玩高级协作，用这个 Discord 版本。

## 🤝 贡献

欢迎 PR，特别想要：

- 让 `claude-dc-pair` 支持 alt 变体（目前只能处理主 bot 的 state 目录）
- 在这个 skill 之上实现一个 multi-bot orchestrator 参考实现（planner / coder / reviewer / tester 模式）
- Slack 适配版本（Slack 目前还没有官方 plugin，需要自建 bridge）

## 📜 License

MIT —— 见 `[LICENSE](LICENSE)`。