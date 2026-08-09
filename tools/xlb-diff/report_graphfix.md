Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
[xlb-diff] sync: no-op (index already fresh)
[FAIL] A1: exact "AI Model" (overlap 67%)
[FAIL] A2: exact "Vibe Coding" (overlap 75%)
[FAIL] A3: exact "Awesome Search" (overlap 82%)
[FAIL] A4: exact "Deep Learning" (overlap 36%)
[FAIL] A5: exact "MCP" (overlap 57%)
[FAIL] A6: substring "vibe cod" (overlap 67%)
[FAIL] A7: substring "deep lea" (overlap 25%)
[FAIL] A8: substring "awesome" (overlap 19%)
[FAIL] A9: substring "model" (overlap 43%)
[FAIL] A10: substring "docker" (overlap 33%)
[FAIL] B1: fuzzy ??vibe (overlap 33%)
[FAIL] B2: fuzzy ??deep learning (overlap 39%)
[PASS] B3: fuzzy ??cursor (overlap 100%)
[FAIL] B4: fuzzy ??rust (overlap 67%)
[FAIL] B5: fuzzy ??paper (overlap 29%)
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
2026-08-02 21:24:06.421 xlb-diff[10259:1706843] [XLBTopicIndex] graphCommunity(Louvain) converged in 21 pass iteration(s), Q=0.8576, 46 clusters (>= 2), 0.798s
[SKIP] E2: community peers of AI Model - community divergent (overlap 9%); py=99 swift=50
[FAIL] F1: case-insensitive "vibe coding" (overlap 75%)
[FAIL] F2: alias probe "gpt-4" (overlap 11%)
[FAIL] F3: category ref "#AI" (overlap 44%)
[FAIL] G1: meta AI Model (overlap 78%)
[FAIL] G2: meta Vibe Coding (overlap 61%)
[PASS] G3: meta Deep Learning (overlap 97%)
[FAIL] G4: meta Docker (overlap 50%)
[PASS] G5: meta MCP (overlap 90%)
# xlb differential test report

## Summary
- Total: 35
- Passed: 11
- Failed: 23
- Skipped: 1

## Failures
### A1: exact "AI Model" (overlap 67%)
- Swift: {ai degree, ai model, ai paper, aigc, baidu cloud, mit csail, stanford ai, state of ai, thailand city list, world model}
- Python: {ai degree, ai model, ai-library, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Missing in Swift: {ai-library, openai-compatible models}
- Extra in Swift: {ai paper, thailand city list}

### A2: exact "Vibe Coding" (overlap 75%)
- Swift: {coding tech talks, vibe coding, vibe design}
- Python: {coding tech talks, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {vibe coding flow/流程/skill}

### A3: exact "Awesome Search" (overlap 82%)
- Swift: {awesome research, awesome search, google search, how to do research, microsoft research, net disk search, search, search engine, social search, vertical search}
- Python: {awesome search, google search, how to do research, microsoft research, net disk search, search, search engine, social search, vertical search, 搜索引擎 project:google search}
- Missing in Swift: {搜索引擎 project:google search}
- Extra in Swift: {awesome research}

### A4: exact "Deep Learning" (overlap 36%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for nlp, deep learning framework, deep reinforcement learning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, deep learning, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {ai and deep learning in 2017, deep learning for computer vision, deeplearning.university, github deep learning, stanford deep learning}
- Extra in Swift: {deep learning for coder, deep learning for nlp, dive into deep learning, mit deep learning}

### A5: exact "MCP" (overlap 57%)
- Swift: {mcp, mcp client, mcp server, mcp servers, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, mcp, mcp client, mcp server, mcp/skill}
- Missing in Swift: {an mcp server to run applescript and jxa}
- Extra in Swift: {mcp servers, skill/mcp}

### A6: substring "vibe cod" (overlap 67%)
- Swift: {code generation, code instrumentation, code reading, code visualization, coding tech talks, low code, papers with code, vibe coding, vibe design, vscode}
- Python: {code generation, code instrumentation, code reading, code visualization, coding tech talks, papers with code, vibe coding, vibe coding flow/流程/skill, vibecodefixers, vscode}
- Missing in Swift: {vibe coding flow/流程/skill, vibecodefixers}
- Extra in Swift: {low code, vibe design}

### A7: substring "deep lea" (overlap 25%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for nlp, deep learning framework, deep reinforcement learning, deeplearning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, ai degree, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {ai and deep learning in 2017, ai degree, deep learning for computer vision, deeplearning.university, github deep learning, stanford deep learning}
- Extra in Swift: {deep learning, deep learning for coder, deep learning for nlp, deeplearning, dive into deep learning, mit deep learning}

### A8: substring "awesome" (overlap 19%)
- Swift: {awesome, awesome 3d reconstruction, awesome ai, awesome ar, awesome architecture, awesome cloudflare, awesome combine, awesome search, awesome-library}
- Python: {awesome, awesome sea, awesome searc, awesome search, awesome searh, awesome star, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome sea, awesome searc, awesome searh, awesome star, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Extra in Swift: {awesome 3d reconstruction, awesome ai, awesome ar, awesome architecture, awesome cloudflare, awesome combine}

### A9: substring "model" (overlap 43%)
- Swift: {3d model, ai model, diffusion probabilistic models, energy-based model, github models, hidden markov model, model, model hub, score-based generative model, world model}
- Python: {3d model, 3d model synthesis, ai model, cesm community earth system model, chaos model, diffusion probabilistic models, github models, model, model synthesis, world model}
- Missing in Swift: {3d model synthesis, cesm community earth system model, chaos model, model synthesis}
- Extra in Swift: {energy-based model, hidden markov model, model hub, score-based generative model}

### A10: substring "docker" (overlap 33%)
- Swift: {android run docker, docker compose, docker desktop, docker ecosystem, docker hub, docker ide, docker image, docker image to dockerfile, docker images, docker inspect}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker-series, docker/replit deploy, docker管理, github:docker}
- Missing in Swift: {docker, docker-series, docker/replit deploy, docker管理, github:docker}
- Extra in Swift: {docker compose, docker ide, docker image, docker images, docker inspect}

### B1: fuzzy ??vibe (overlap 33%)
- Swift: {streaming tts/realtime tts/vibevoice, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {south korea vibe walk, streaming tts/realtime tts/vibevoice, vibe coding, vibe coding flow/流程/skill, vibe design, vibecodefixers}
- Missing in Swift: {south korea vibe walk, vibe coding flow/流程/skill, vibecodefixers}
- Extra in Swift: {vibe, vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 39%)
- Swift: {ai and deep learning in 2017, ai degree, cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep reinforcement learning, deeplearning, deeplearning resources, deeplearning.university, dive into deep learning, learning deep, mit deep learning, siliconvalleydeeplearning, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for computer vision, deep learning for games, deep learning for natural language processing, deep learning framework, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, deep reinforcement learning, deeplearning.university, dive into deep learning book, github deep learning, machine learning, mit 6.s191 introduction to deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {deep learning for computer vision, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, dive into deep learning book, github deep learning, machine learning, mit 6.s191 introduction to deep learning}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for nlp, deeplearning, deeplearning resources, dive into deep learning, learning deep, mit deep learning}

### B4: fuzzy ??rust (overlap 67%)
- Swift: {artificial general intelligence, cpp@>rust, crust of rust, downward thrust, embedded rust, rust, rust lang, rust zh, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Extra in Swift: {cpp@>rust, crust of rust, embedded rust, rust zh}

### B5: fuzzy ??paper (overlap 29%)
- Swift: {agent papers, ai paper, ai paper source, ai papers, autonomous driving, awesome paper, biorxiv/medrxiv/paper, cell papers, cgf paper, chat with paper/paper to blog, chat with pdf/doc/paper, gi-papers, graph paper, how to read paper, how to trace paper, how to write paper, hu-po livestreams on ml papers coding research, ingo wald paper, kesen paper, papers with code}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, papers, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Missing in Swift: {awesome.paper, how to finding papers, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, papers, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Extra in Swift: {agent papers, ai paper source, ai papers, awesome paper, biorxiv/medrxiv/paper, cell papers, chat with paper/paper to blog, chat with pdf/doc/paper, graph paper, hu-po livestreams on ml papers coding research, kesen paper}

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

### F1: case-insensitive "vibe coding" (overlap 75%)
- Swift: {coding tech talks, vibe coding, vibe design}
- Python: {coding tech talks, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {vibe coding flow/流程/skill}

### F2: alias probe "gpt-4" (overlap 11%)
- Swift: {chat with ai/bloomberggpt, chat with marketinggpt, chatgpt, chatgpt api, chatgpt coding, chatgpt executor, chatgpt for wechat/chat with ai, gpt, gpt 4, gpt-3}
- Python: {agi by gpt-7, autogpt, chatgpt, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt}
- Missing in Swift: {agi by gpt-7, autogpt, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt}
- Extra in Swift: {chat with ai/bloomberggpt, chat with marketinggpt, chatgpt api, chatgpt coding, chatgpt for wechat/chat with ai, gpt, gpt 4, gpt-3}

### F3: category ref "#AI" (overlap 44%)
- Swift: {ai, ai engineer, ai model, ai paper, ai programming, ai project, ai-library, berkeley ai, blackshark ai, chat with ai, cmu ai, facebook ai, game ai, grok ai, multimodal ai, personalized ai, pony ai, stanford ai, state of ai}
- Python: {ai, ai anime/ai 动画, ai engineer, ai model, ai paper, ai programming, ai project, ai scraping/chat with crawler, ai-library, aigc, baidu cloud, facebook ai, grok ai, mit csail, multimodal ai, stanford ai, state of ai, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Missing in Swift: {ai anime/ai 动画, ai scraping/chat with crawler, aigc, baidu cloud, mit csail, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Extra in Swift: {berkeley ai, blackshark ai, chat with ai, cmu ai, game ai, personalized ai, pony ai}

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
- E2 community peers of AI Model: community divergent (overlap 9%); py=99 swift=50

