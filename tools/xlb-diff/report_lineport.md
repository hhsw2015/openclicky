Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
[xlb-diff] sync: no-op (index already fresh)
[FAIL] A1: exact "AI Model" (overlap 67%)
[PASS] A2: exact "Vibe Coding" (overlap 100%)
[FAIL] A3: exact "Awesome Search" (overlap 82%)
[FAIL] A4: exact "Deep Learning" (overlap 43%)
[PASS] A5: exact "MCP" (overlap 100%)
[FAIL] A6: substring "vibe cod" (overlap 82%)
[FAIL] A7: substring "deep lea" (overlap 43%)
[FAIL] A8: substring "awesome" (overlap 31%)
[FAIL] A9: substring "model" (overlap 27%)
[FAIL] A10: substring "docker" (overlap 43%)
[PASS] B1: fuzzy ??vibe (overlap 100%)
[FAIL] B2: fuzzy ??deep learning (overlap 70%)
[PASS] B3: fuzzy ??cursor (overlap 100%)
[FAIL] B4: fuzzy ??rust (overlap 88%)
[FAIL] B5: fuzzy ??paper (overlap 70%)
[PASS] C1: path Vibe Coding -> AI (overlap 100%)
[FAIL] C2: path Vibe Coding -> LLM (overlap 0%)
[PASS] C3: path Vibe Coding -> Cursor (overlap 100%)
[PASS] C4: path PyTorch -> AI Model (overlap 100%)
[PASS] C5: path Deep Learning -> Transformer (overlap 100%)
[PASS] D1: explore AI Model hops=1 (overlap 96%)
[PASS] D2: explore Vibe Coding hops=1 (overlap 100%)
[FAIL] D3: explore PyTorch hops=2 (overlap 86%)
[FAIL] D4: explore Docker hops=1 (overlap 0%)
[PASS] D5: explore MCP hops=1 (overlap 100%)
[PASS] E1: hubs top 10 (overlap 82%)
2026-08-03 11:17:17.040 xlb-diff[38814:451227] [XLBTopicIndex] graphCommunity(Louvain) converged in 21 pass iteration(s), Q=0.8584, 42 clusters (>= 2), 0.811s
[SKIP] E2: community peers of AI Model - community divergent (overlap 8%); py=99 swift=50
[PASS] F1: case-insensitive "vibe coding" (overlap 100%)
[FAIL] F2: alias probe "gpt-4" (overlap 54%)
[FAIL] F3: category ref "#AI" (overlap 48%)
[FAIL] G1: meta AI Model (overlap 78%)
[FAIL] G2: meta Vibe Coding (overlap 61%)
[PASS] G3: meta Deep Learning (overlap 97%)
[FAIL] G4: meta Docker (overlap 50%)
[PASS] G5: meta MCP (overlap 90%)
# xlb differential test report

## Summary
- Total: 35
- Passed: 15
- Failed: 19
- Skipped: 1

## Failures
### A1: exact "AI Model" (overlap 67%)
- Swift: {ai degree, ai model, ai paper, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, thailand city list}
- Python: {ai degree, ai model, ai-library, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Missing in Swift: {ai-library, world model}
- Extra in Swift: {ai paper, thailand city list}

### A3: exact "Awesome Search" (overlap 82%)
- Swift: {awesome search, how to do research, magnet search, microsoft research, net disk search, search, search engine, social search, vertical search, 搜索引擎 project:google search}
- Python: {awesome search, google search, how to do research, microsoft research, net disk search, search, search engine, social search, vertical search, 搜索引擎 project:google search}
- Missing in Swift: {google search}
- Extra in Swift: {magnet search}

### A4: exact "Deep Learning" (overlap 43%)
- Swift: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for games, deep learning for natural language processing, deep reinforcement learning, deeplearning.university, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, deep learning, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {deep learning for computer vision, deep learning framework, github deep learning, stanford deep learning}
- Extra in Swift: {ai degree, deep learning for games, deep learning for natural language processing, mit deep learning}

### A6: substring "vibe cod" (overlap 82%)
- Swift: {code generation, code instrumentation, code reading, code visualization, coding tech talks, vibe coding, vibe coding flow/流程/skill, vibe design, vibecodefixers, vscode}
- Python: {code generation, code instrumentation, code reading, code visualization, coding tech talks, papers with code, vibe coding, vibe coding flow/流程/skill, vibecodefixers, vscode}
- Missing in Swift: {papers with code}
- Extra in Swift: {vibe design}

### A7: substring "deep lea" (overlap 43%)
- Swift: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for games, deep learning for natural language processing, deep reinforcement learning, deeplearning.university, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, ai degree, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {deep learning for computer vision, deep learning framework, github deep learning, stanford deep learning}
- Extra in Swift: {deep learning, deep learning for games, deep learning for natural language processing, mit deep learning}

### A8: substring "awesome" (overlap 31%)
- Swift: {awesome, awesome list/repo sort, awesome search, awesome star, curated list of awesome things regarding webassembly, mfatihmar/awesome-game-networking project:spatialos, most awesome game}
- Python: {awesome, awesome sea, awesome searc, awesome search, awesome searh, awesome star, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome sea, awesome searc, awesome searh, awesome-library, awesome.paper, awesome//:combine}
- Extra in Swift: {awesome list/repo sort, curated list of awesome things regarding webassembly, most awesome game}

### A9: substring "model" (overlap 27%)
- Swift: {ai, ai model, artificial general intelligence, artificial intelligence, cloudflare models, computer graphics and modeling, github models, model, world model}
- Python: {3d model, 3d model synthesis, ai model, cesm community earth system model, chaos model, diffusion probabilistic models, github models, model, model synthesis, world model}
- Missing in Swift: {3d model, 3d model synthesis, cesm community earth system model, chaos model, diffusion probabilistic models, model synthesis}
- Extra in Swift: {ai, artificial general intelligence, artificial intelligence, cloudflare models, computer graphics and modeling}

### A10: substring "docker" (overlap 43%)
- Swift: {android run docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker images, docker inspect, docker proxy/加速, docker/replit deploy, docker瘦身}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker-series, docker/replit deploy, docker管理, github:docker}
- Missing in Swift: {docker, docker-series, docker管理, github:docker}
- Extra in Swift: {docker images, docker inspect, docker proxy/加速, docker瘦身}

### B2: fuzzy ??deep learning (overlap 70%)
- Swift: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for games, deep learning for natural language processing, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, deep reinforcement learning, deeplearning.university, dive into deep learning book, machine learning, mit 6.s191 introduction to deep learning, mit deep learning, nvidia deep learning institute, sdcnd, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for computer vision, deep learning for games, deep learning for natural language processing, deep learning framework, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, deep reinforcement learning, deeplearning.university, dive into deep learning book, github deep learning, machine learning, mit 6.s191 introduction to deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {deep learning for computer vision, deep learning framework, github deep learning, stanford deep learning}
- Extra in Swift: {mit deep learning, nvidia deep learning institute, sdcnd}

### B4: fuzzy ??rust (overlap 88%)
- Swift: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Missing in Swift: {trustable}

### B5: fuzzy ??paper (overlap 70%)
- Swift: {ai paper, autonomous driving, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, mark papermaster, minute papers, paper discussion, paper reading club, papers, papers with code, stanford graphics paper, the landscape of biomedical/paper map, two minute papers, wallpaper engine/live wallpaper/动态壁纸/美化}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, papers, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Missing in Swift: {awesome.paper, paper, paper explaine & ??papers explaine & ??paper-reading, 壁纸/wallpaper}
- Extra in Swift: {stanford graphics paper, the landscape of biomedical/paper map, two minute papers}

### C2: path Vibe Coding -> LLM (overlap 0%)
- Swift: {Vibe Coding, Awesome Search, llm}
- Python: {}
- Extra in Swift: {Vibe Coding, Awesome Search, llm}

### D3: explore PyTorch hops=2 (overlap 86%)
- Swift: {ai paper, alfredo canziani, andrew ng, jeremy howard, lex fridman, mlcourse ai}
- Python: {ai paper, alfredo canziani, andrew ng, jeremy howard, lex fridman, mlcourse ai, ng}
- Missing in Swift: {ng}

### D4: explore Docker hops=1 (overlap 0%)
- Swift: {}
- Python: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}
- Missing in Swift: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}

### F2: alias probe "gpt-4" (overlap 54%)
- Swift: {agi by gpt-7, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, detect gpt, gpts, 共享账号/注册/解锁chatgpt/share key/gpt4, 流媒体/chatgpt解锁/测试}
- Python: {agi by gpt-7, autogpt, chatgpt, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt}
- Missing in Swift: {autogpt, chatgpt, deep dive into llms like chatgpt}
- Extra in Swift: {gpts, 共享账号/注册/解锁chatgpt/share key/gpt4, 流媒体/chatgpt解锁/测试}

### F3: category ref "#AI" (overlap 48%)
- Swift: {ai, ai engineer, ai model, ai paper, ai programming, ai project, baidu cloud, berkeley ai, blackshark ai, cmu ai, facebook ai, grok ai, mit csail, multimodal ai, personalized ai, pony ai, stanford ai, state of ai, thailand city list, uber ai}
- Python: {ai, ai anime/ai 动画, ai engineer, ai model, ai paper, ai programming, ai project, ai scraping/chat with crawler, ai-library, aigc, baidu cloud, facebook ai, grok ai, mit csail, multimodal ai, stanford ai, state of ai, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Missing in Swift: {ai anime/ai 动画, ai scraping/chat with crawler, ai-library, aigc, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Extra in Swift: {berkeley ai, blackshark ai, cmu ai, personalized ai, pony ai, thailand city list, uber ai}

### G1: meta AI Model (overlap 78%)
- Swift: {ai workspace, ai2api, aigc, alibaba qwen, anthropic claude, data center, deepseek, doubao, github, grok ai, hugging face, intelligent agent, linux do, mcp, microsoft copilot, openai, reverse engineering, searchin, skywork, web developer, ...+2}
- Python: {ai workspace, aigc, alibaba qwen, anthropic claude, deepseek, doubao, github, grok ai, hugging face, microsoft copilot, openai, searchin, website, youtube}
- Extra in Swift: {ai2api, data center, intelligent agent, linux do, mcp, reverse engineering, skywork, web developer}

### G2: meta Vibe Coding (overlap 61%)
- Swift: {agent computer interface, agent skills, ai model, ai programming, alibaba qwen, andrej karpathy, anthropic claude, augment code, awesome star, bolt new, code generation, code reading, codex cli, command, command-line interface, crush, cursor editor, discord, forge code, github, ...+33}
- Python: {agent computer interface, ai model, ai programming, andrej karpathy, anthropic claude, code generation, command, discord, github, github inc, input method, intelligent agent, programmer skill map, reddit, searchin, website, y-playlist, y-video, youtube}
- Extra in Swift: {agent skills, alibaba qwen, augment code, awesome star, bolt new, code reading, codex cli, command-line interface, crush, cursor editor, forge code, github copilot, google antigravity, google gemini, grok ai, kimi ai, kiro, low code, mcp, minimax ai, ...+14}

### G4: meta Docker (overlap 50%)
- Swift: {}
- Python: {website}
- Missing in Swift: {website}

## Skipped
- E2 community peers of AI Model: community divergent (overlap 8%); py=99 swift=50

