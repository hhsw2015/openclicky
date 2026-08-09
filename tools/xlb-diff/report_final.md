[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
[xlb-diff] sync: no-op (index already fresh)
[FAIL] A1: exact "AI Model" (overlap 18%)
[FAIL] A2: exact "Vibe Coding" (overlap 15%)
[FAIL] A3: exact "Awesome Search" (overlap 25%)
[FAIL] A4: exact "Deep Learning" (overlap 11%)
[FAIL] A5: exact "MCP" (overlap 50%)
[FAIL] A6: substring "vibe cod" (overlap 33%)
[FAIL] A7: substring "deep lea" (overlap 5%)
[FAIL] A8: substring "awesome" (overlap 11%)
[FAIL] A9: substring "model" (overlap 25%)
[FAIL] A10: substring "docker" (overlap 18%)
[FAIL] B1: fuzzy ??vibe (overlap 29%)
[FAIL] B2: fuzzy ??deep learning (overlap 21%)
[PASS] B3: fuzzy ??cursor (overlap 100%)
[FAIL] B4: fuzzy ??rust (overlap 58%)
[FAIL] B5: fuzzy ??paper (overlap 11%)
[PASS] C1: path Vibe Coding -> AI (overlap 100%)
[FAIL] C2: path Vibe Coding -> LLM (overlap 0%)
[PASS] C3: path Vibe Coding -> Cursor (overlap 100%)
[PASS] C4: path PyTorch -> AI Model (overlap 100%)
[PASS] C5: path Deep Learning -> Transformer (overlap 100%)
[FAIL] D1: explore AI Model hops=1 (overlap 83%)
[FAIL] D2: explore Vibe Coding hops=1 (overlap 78%)
[PASS] D3: explore PyTorch hops=2 (overlap 100%)
[FAIL] D4: explore Docker hops=1 (overlap 0%)
[PASS] D5: explore MCP hops=1 (overlap 90%)
[PASS] E1: hubs top 10 (overlap 82%)
2026-08-02 16:31:00.126 xlb-diff[26493:1126114] [XLBTopicIndex] graphCommunity(Louvain) converged in 14 pass iteration(s), Q=0.7825, 62 clusters (>= 2), 0.243s
[SKIP] E2: community peers of AI Model - community divergent (overlap 14%); py=99 swift=50
[FAIL] F1: case-insensitive "vibe coding" (overlap 15%)
[FAIL] F2: alias probe "gpt-4" (overlap 5%)
[FAIL] F3: category ref "#AI" (overlap 43%)
[FAIL] G1: meta AI Model (overlap 78%)
[FAIL] G2: meta Vibe Coding (overlap 61%)
[FAIL] G3: meta Deep Learning (overlap 85%)
[FAIL] G4: meta Docker (overlap 50%)
[PASS] G5: meta MCP (overlap 90%)
# xlb differential test report

## Summary
- Total: 35
- Passed: 9
- Failed: 25
- Skipped: 1

## Failures
### A1: exact "AI Model" (overlap 18%)
- Swift: {ai model, ai paper, ai programming, aigc, baidu cloud, mit csail, stanford ai, state of ai, thailand city list, world model}
- Python: {aigc, berkeley ai, blockchain, brainstorm, facebook ai, sony interactive entertainment, stanford ai, the blockchain, the supply chain, world model}
- Missing in Swift: {berkeley ai, blockchain, brainstorm, facebook ai, sony interactive entertainment, the blockchain, the supply chain}
- Extra in Swift: {ai model, ai paper, ai programming, baidu cloud, mit csail, state of ai, thailand city list}

### A2: exact "Vibe Coding" (overlap 15%)
- Swift: {ai coding, coding, coding tools, creative coding, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {coding tech talks, guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tools, creative coding, decoding, vibe, vibe/转录, vibeshell}

### A3: exact "Awesome Search" (overlap 25%)
- Swift: {awesome research, awesome search, google search, how to do research, magnet search, microsoft research, net disk search, social search, subscription search, vertical search}
- Python: {company search, ebook search, file search, how to search, microsoft research, nvidia research, snapshot search, social search, subscription search, vertical search}
- Missing in Swift: {company search, ebook search, file search, how to search, nvidia research, snapshot search}
- Extra in Swift: {awesome research, awesome search, google search, how to do research, magnet search, net disk search}

### A4: exact "Deep Learning" (overlap 11%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, multimodal deep learning, stanford deep learning}
- Python: {ai and deep learning in 2017, cs230 deep learning i autumn 2025, deep learning, deep learning and generative models course, deep learning for coders, deep learning for games, deep learning for natural language processing, deep learning i spring 2024 i professor christopher manning, deeplearning.university, learning lecture series 2020 deepmind x ucl}
- Missing in Swift: {ai and deep learning in 2017, cs230 deep learning i autumn 2025, deep learning and generative models course, deep learning for coders, deep learning for games, deep learning i spring 2024 i professor christopher manning, deeplearning.university, learning lecture series 2020 deepmind x ucl}
- Extra in Swift: {deep learning book, deep learning for coder, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, multimodal deep learning, stanford deep learning}

### A5: exact "MCP" (overlap 50%)
- Swift: {mcp, mcp client, mcp server, mcp servers, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, api to mcp, mcp, mcp client, mcp server, mcp/skill}
- Missing in Swift: {an mcp server to run applescript and jxa, api to mcp}
- Extra in Swift: {mcp servers, skill/mcp}

### A6: substring "vibe cod" (overlap 33%)
- Swift: {code editor, code generation, code reading, code search, code visualization, low code, papers with code, vibe coding, vibe design, vscode}
- Python: {code encryption, code generation, code obfuscation, code visualization, coding tech talks, github codespaces, low code, open code, vibe coding, vscode}
- Missing in Swift: {code encryption, code obfuscation, coding tech talks, github codespaces, open code}
- Extra in Swift: {code editor, code reading, code search, papers with code, vibe design}

### A7: substring "deep lea" (overlap 5%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, multimodal deep learning, stanford deep learning}
- Python: {ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning i autumn 2025, cs330 deep multi-task and meta learning i autumn 2022, deep learning, deep learning for coders, deep learning i2dl 2020, deep learning i2dl 2023, github deep learning, siliconvalleydeeplearning}
- Missing in Swift: {ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning i autumn 2025, cs330 deep multi-task and meta learning i autumn 2022, deep learning for coders, deep learning i2dl 2020, deep learning i2dl 2023, github deep learning, siliconvalleydeeplearning}
- Extra in Swift: {deep learning book, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, multimodal deep learning, stanford deep learning}

### A8: substring "awesome" (overlap 11%)
- Swift: {awesome, awesome ai, awesome ar, awesome game engine, awesome gaussian splatting, awesome graphics, awesome mr, awesome search, awesome star, awesome vr}
- Python: {awesome, awesome list/repo sort, awesome sea, awesome searc, awesome searh, awesome star, awesome.paper, curated list of awesome things regarding webassembly, mfatihmar/awesome-game-networking project:spatialos, most awesome game}
- Missing in Swift: {awesome list/repo sort, awesome sea, awesome searc, awesome searh, awesome.paper, curated list of awesome things regarding webassembly, mfatihmar/awesome-game-networking project:spatialos, most awesome game}
- Extra in Swift: {awesome ai, awesome ar, awesome game engine, awesome gaussian splatting, awesome graphics, awesome mr, awesome search, awesome vr}

### A9: substring "model" (overlap 25%)
- Swift: {3d model synthesis, ai model, cloudflare models, github models, language model, model, modelarts, modeling, models, world model}
- Python: {3d model synthesis, artificial intelligence, model, model context protocol, model synthesis, modelarts, probabilistic graph model, v-model, waterfall model, world model}
- Missing in Swift: {artificial intelligence, model context protocol, model synthesis, probabilistic graph model, v-model, waterfall model}
- Extra in Swift: {ai model, cloudflare models, github models, language model, modeling, models}

### A10: substring "docker" (overlap 18%)
- Swift: {docker compose, docker hub, docker ide, docker image, docker root, docker series, docker@>lxc, docker瘦身, docker管理, github docker}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker images, docker/replit deploy, docker瘦身, docker管理, play with docker/playground}
- Missing in Swift: {android run docker, docker, docker desktop, docker ecosystem, docker images, docker/replit deploy, play with docker/playground}
- Extra in Swift: {docker compose, docker ide, docker image, docker root, docker series, docker@>lxc, github docker}

### B1: fuzzy ??vibe (overlap 29%)
- Swift: {streaming tts/realtime tts/vibevoice, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {guide to vibe coding, relaxing vibe, south korea vibe walk, streaming tts/realtime tts/vibevoice, vacation vibes driving india, vibe, vibe coding, vibe coding flow/流程/skill, vibe design, vibe gaming, vibecodefixers, vibes}
- Missing in Swift: {guide to vibe coding, relaxing vibe, south korea vibe walk, vacation vibes driving india, vibe coding flow/流程/skill, vibe gaming, vibecodefixers, vibes}
- Extra in Swift: {vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 21%)
- Swift: {ai and deep learning in 2017, cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, dive into deep learning, github deep learning, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, deep learning, deep learning and generative models course, deep learning book, deep learning for computer vision, deep learning for natural language processing, deep learning framework, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, deep learning indaba, deep reinforcement learning, github deep learning, learning course deepmind x ucl, learning lecture series 2020 deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Missing in Swift: {ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, deep learning and generative models course, deep learning for computer vision, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, deep reinforcement learning, learning course deepmind x ucl, learning lecture series 2020 deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for games, deep learning for nlp, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, dive into deep learning, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, stanford deep learning}

### B4: fuzzy ??rust (overlap 58%)
- Swift: {cpp@>rust, crust of rust, downward thrust, embedded rust, rust, rust lang, rust zh, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Missing in Swift: {artificial general intelligence}
- Extra in Swift: {cpp@>rust, crust of rust, embedded rust, rust zh}

### B5: fuzzy ??paper (overlap 11%)
- Swift: {agent papers, ai paper, ai papers, awesome paper, cell papers, learning papers, llm papers, paper explaine, paper list, papers, papers for, papers with code, paperweekly, paper翻译, pretraining papers, qai papers, rl papers, segmentation papers, system papers, two minute papers}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, how to finding papers, how to read paper, how to write paper, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper source, papers, papers slop, papers with code, two minute papers, white papers, 区块链papers, 壁纸/wallpaper}
- Missing in Swift: {autonomous driving, awesome.paper, cgf paper, how to finding papers, how to read paper, how to write paper, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper source, papers slop, white papers, 区块链papers, 壁纸/wallpaper}
- Extra in Swift: {agent papers, ai papers, awesome paper, cell papers, learning papers, llm papers, paper explaine, paper list, papers for, paperweekly, paper翻译, pretraining papers, qai papers, rl papers, segmentation papers, system papers}

### C2: path Vibe Coding -> LLM (overlap 0%)
- Swift: {Vibe Coding, Awesome Search, llm}
- Python: {Vibe Coding, AI Model, Artificial Intelligence, ai-library, Convolutional Neural Networks for Visual Recognition, Deep Dive into LLMs like ChatGPT}
- Missing in Swift: {Vibe Coding, AI Model, Artificial Intelligence, ai-library, Convolutional Neural Networks for Visual Recognition, Deep Dive into LLMs like ChatGPT}
- Extra in Swift: {Vibe Coding, Awesome Search, llm}

### D1: explore AI Model hops=1 (overlap 83%)
- Swift: {ai engineer, ai workspace, ai2api, aigc, alibaba qwen, anthropic claude, cloud agent, data center, deepseek, doubao, grok ai, how to do research, how to make money, how to thinking, hugging face, intelligent agent, linux do, mcp, microsoft copilot, openai, ...+4}
- Python: {ai engineer, ai2api, aigc, alibaba qwen, anthropic claude, cloud agent, deepseek, doubao, grok ai, how to do research, how to make money, how to thinking, hugging face, intelligent agent, mcp, microsoft copilot, openai, reverse engineering, vibe coding, web developer}
- Extra in Swift: {ai workspace, data center, linux do, skywork}

### D2: explore Vibe Coding hops=1 (overlap 78%)
- Swift: {agent computer interface, agent skills, ai engineer, ai harness, ai model, ai programming, alibaba qwen, andrej karpathy, anthropic claude, augment code, awesome star, bolt new, cloud agent, code generation, code reading, codex cli, command-line interface, crush, cursor editor, forge code, ...+30}
- Python: {agent skills, ai engineer, ai model, ai programming, alibaba qwen, andrej karpathy, anthropic claude, augment code, awesome star, bolt new, cloud agent, code generation, code reading, codex cli, crush, cursor editor, forge code, github copilot, google antigravity, google gemini, ...+19}
- Extra in Swift: {agent computer interface, ai harness, command-line interface, github inc, how to start a startup, kimi ai, minimax ai, programmer skill map, qoder, terminal user interface, warp}

### D4: explore Docker hops=1 (overlap 0%)
- Swift: {}
- Python: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}
- Missing in Swift: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}

### F1: case-insensitive "vibe coding" (overlap 15%)
- Swift: {ai coding, coding, coding tools, creative coding, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {coding tech talks, guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tools, creative coding, decoding, vibe, vibe/转录, vibeshell}

### F2: alias probe "gpt-4" (overlap 5%)
- Swift: {chatgpt, chatgpt api, cli chatgpt, gpt, gpt 3, gpt 4, gpt store, gpt4, gpts, nanogpt}
- Python: {agi by gpt-7, autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, dive into llms like chatgpt, express/remove bg/chatgpt/play ht/d-id/descript, gpt, 流媒体/chatgpt解锁/测试}
- Missing in Swift: {agi by gpt-7, autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, dive into llms like chatgpt, express/remove bg/chatgpt/play ht/d-id/descript, 流媒体/chatgpt解锁/测试}
- Extra in Swift: {chatgpt, chatgpt api, cli chatgpt, gpt 3, gpt 4, gpt store, gpt4, gpts, nanogpt}

### F3: category ref "#AI" (overlap 43%)
- Swift: {ai, ai engineer, ai model, ai paper, ai programming, aifromscratch, aigc, baidu cloud, domain language, google brain, google gmail, how brain work, mit csail, multimodal ai, sony interactive entertainment, spain city list, stanford ai, state of ai, thailand city list, the blockchain}
- Python: {ai anime/ai 动画, ai engineer, ai model, ai project, ai scraping/chat with crawler, baidu cloud, blockchain, domain language, facebook ai, game ai engine, google brain, google gmail, grok ai, how brain work, multimodal ai, sony interactive entertainment, stanford ai, state of ai, the blockchain, 图像修复/image restoration/ai修复/ai restor}
- Missing in Swift: {ai anime/ai 动画, ai project, ai scraping/chat with crawler, blockchain, facebook ai, game ai engine, grok ai, 图像修复/image restoration/ai修复/ai restor}
- Extra in Swift: {ai, ai paper, ai programming, aifromscratch, aigc, mit csail, spain city list, thailand city list}

### G1: meta AI Model (overlap 78%)
- Swift: {ai workspace, ai2api, aigc, alibaba qwen, anthropic claude, data center, deepseek, doubao, github, grok ai, hugging face, intelligent agent, linux do, mcp, microsoft copilot, openai, reverse engineering, searchin, skywork, web developer, ...+2}
- Python: {aigc, alibaba qwen, anthropic claude, deepseek, doubao, github, grok ai, hugging face, intelligent agent, microsoft copilot, openai, searchin, website, youtube}
- Extra in Swift: {ai workspace, ai2api, data center, linux do, mcp, reverse engineering, skywork, web developer}

### G2: meta Vibe Coding (overlap 61%)
- Swift: {agent computer interface, agent skills, ai model, ai programming, alibaba qwen, andrej karpathy, anthropic claude, augment code, awesome star, bolt new, code generation, code reading, codex cli, command, command-line interface, crush, cursor editor, discord, forge code, github, ...+33}
- Python: {ai model, ai programming, andrej karpathy, anthropic claude, code generation, command, discord, github, github copilot, google gemini, input method, intelligent agent, openai, reddit, searchin, website, y-playlist, y-video, youtube}
- Extra in Swift: {agent computer interface, agent skills, alibaba qwen, augment code, awesome star, bolt new, code reading, codex cli, command-line interface, crush, cursor editor, forge code, github inc, google antigravity, grok ai, kimi ai, kiro, low code, mcp, minimax ai, ...+14}

### G3: meta Deep Learning (overlap 85%)
- Swift: {alias, alternativeto, baiduyun, bilibili, blog, book, channel9, command, commonlounge, douyu, facebook, fb-group, github, hugging_face, huggingface, juejin, linkedin, medium, memkite, paper, ...+14}
- Python: {alias, alternativeto, baiduyun, blog, command, conference, douyu, facebook, fb-group, github, homepage, hugging_face, huggingface, juejin, medium, paper, path, people, reddit, searchin, ...+12}
- Missing in Swift: {conference, homepage, path, survey, weixin}
- Extra in Swift: {bilibili, book, channel9, commonlounge, linkedin, memkite, paperswithcode}

### G4: meta Docker (overlap 50%)
- Swift: {}
- Python: {website}
- Missing in Swift: {website}

## Skipped
- E2 community peers of AI Model: community divergent (overlap 14%); py=99 swift=50

