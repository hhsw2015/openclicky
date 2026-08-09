Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
[xlb-diff] sync: no-op (index already fresh)
[FAIL] A1: exact "AI Model" (overlap 67%)
[FAIL] A2: exact "Vibe Coding" (overlap 60%)
[FAIL] A3: exact "Awesome Search" (overlap 67%)
[FAIL] A4: exact "Deep Learning" (overlap 19%)
[FAIL] A5: exact "MCP" (overlap 50%)
[FAIL] A6: substring "vibe cod" (overlap 54%)
[FAIL] A7: substring "deep lea" (overlap 11%)
[FAIL] A8: substring "awesome" (overlap 19%)
[FAIL] A9: substring "model" (overlap 33%)
[FAIL] A10: substring "docker" (overlap 33%)
[FAIL] B1: fuzzy ??vibe (overlap 29%)
[FAIL] B2: fuzzy ??deep learning (overlap 11%)
[PASS] B3: fuzzy ??cursor (overlap 100%)
[FAIL] B4: fuzzy ??rust (overlap 67%)
[FAIL] B5: fuzzy ??paper (overlap 29%)
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
2026-08-02 21:01:12.080 xlb-diff[93143:1665036] [XLBTopicIndex] graphCommunity(Louvain) converged in 21 pass iteration(s), Q=0.8576, 46 clusters (>= 2), 0.756s
[SKIP] E2: community peers of AI Model - community divergent (overlap 3%); py=99 swift=50
[FAIL] F1: case-insensitive "vibe coding" (overlap 60%)
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
- Passed: 10
- Failed: 24
- Skipped: 1

## Failures
### A1: exact "AI Model" (overlap 67%)
- Swift: {ai degree, ai model, ai paper, aigc, baidu cloud, mit csail, stanford ai, state of ai, thailand city list, world model}
- Python: {ai degree, ai model, ai-library, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Missing in Swift: {ai-library, openai-compatible models}
- Extra in Swift: {ai paper, thailand city list}

### A2: exact "Vibe Coding" (overlap 60%)
- Swift: {coding tech talks, vibe coding, vibe design}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {guide to vibe coding, vibe coding flow/流程/skill}

### A3: exact "Awesome Search" (overlap 67%)
- Swift: {awesome research, awesome search, google search, how to do research, microsoft research, net disk search, search, search engine, social search, vertical search}
- Python: {awesome search, google search, how to do research, microsoft research, net disk search, research-library, search engine, social search, vertical search, 搜索引擎 project:google search}
- Missing in Swift: {research-library, 搜索引擎 project:google search}
- Extra in Swift: {awesome research, search}

### A4: exact "Deep Learning" (overlap 19%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for nlp, deep learning framework, deep reinforcement learning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning, deep learning framework, deep reinforcement learning}
- Missing in Swift: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022}
- Extra in Swift: {deep learning book, deep learning for coder, deep learning for nlp, dive into deep learning, mit deep learning, siliconvalleydeeplearning}

### A5: exact "MCP" (overlap 50%)
- Swift: {mcp, mcp client, mcp server, mcp servers, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, api to mcp, mcp, mcp client, mcp server, mcp/skill}
- Missing in Swift: {an mcp server to run applescript and jxa, api to mcp}
- Extra in Swift: {mcp servers, skill/mcp}

### A6: substring "vibe cod" (overlap 54%)
- Swift: {code generation, code instrumentation, code reading, code visualization, coding tech talks, low code, papers with code, vibe coding, vibe design, vscode}
- Python: {code generation, code instrumentation, code reading, coding tech talks, guide to vibe coding, papers with code, vibe coding, vibe coding flow/流程/skill, vibecodefixers, vscode}
- Missing in Swift: {guide to vibe coding, vibe coding flow/流程/skill, vibecodefixers}
- Extra in Swift: {code visualization, low code, vibe design}

### A7: substring "deep lea" (overlap 11%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for nlp, deep learning framework, deep reinforcement learning, deeplearning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning and generative models course, deep learning framework, deep reinforcement learning}
- Missing in Swift: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning and generative models course}
- Extra in Swift: {deep learning, deep learning book, deep learning for coder, deep learning for nlp, deeplearning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}

### A8: substring "awesome" (overlap 19%)
- Swift: {awesome, awesome 3d reconstruction, awesome ai, awesome ar, awesome architecture, awesome cloudflare, awesome combine, awesome search, awesome-library}
- Python: {awesome, awesome sea, awesome searc, awesome search, awesome searh, awesome star, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome sea, awesome searc, awesome searh, awesome star, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Extra in Swift: {awesome 3d reconstruction, awesome ai, awesome ar, awesome architecture, awesome cloudflare, awesome combine}

### A9: substring "model" (overlap 33%)
- Swift: {3d model, ai model, diffusion probabilistic models, energy-based model, github models, hidden markov model, model, model hub, score-based generative model, world model}
- Python: {3d model, 3d model synthesis, ai model, cesm community earth system model, chaos model, cs236 deep generative models i 2023 i stefano ermon, github models, model, model synthesis, world model}
- Missing in Swift: {3d model synthesis, cesm community earth system model, chaos model, cs236 deep generative models i 2023 i stefano ermon, model synthesis}
- Extra in Swift: {diffusion probabilistic models, energy-based model, hidden markov model, model hub, score-based generative model}

### A10: substring "docker" (overlap 33%)
- Swift: {android run docker, docker compose, docker desktop, docker ecosystem, docker hub, docker ide, docker image, docker image to dockerfile, docker images, docker inspect}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker-series, docker/replit deploy, docker管理, github:docker}
- Missing in Swift: {docker, docker-series, docker/replit deploy, docker管理, github:docker}
- Extra in Swift: {docker compose, docker ide, docker image, docker images, docker inspect}

### B1: fuzzy ??vibe (overlap 29%)
- Swift: {streaming tts/realtime tts/vibevoice, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {guide to vibe coding, relaxing vibe, south korea vibe walk, streaming tts/realtime tts/vibevoice, vacation vibes driving india, vibe, vibe coding, vibe coding flow/流程/skill, vibe design, vibe gaming, vibecodefixers, vibes}
- Missing in Swift: {guide to vibe coding, relaxing vibe, south korea vibe walk, vacation vibes driving india, vibe coding flow/流程/skill, vibe gaming, vibecodefixers, vibes}
- Extra in Swift: {vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 11%)
- Swift: {ai and deep learning in 2017, ai degree, cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep reinforcement learning, deeplearning, deeplearning resources, deeplearning.university, dive into deep learning, learning deep, mit deep learning, siliconvalleydeeplearning, stanford deep learning}
- Python: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning, deep learning and generative models course, deep learning for coders, deep learning for computer vision, deep learning framework, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, deep reinforcement learning, deeplearning.university, github deep learning, intro to deep learning, language processing with deep learning course winter 2019}
- Missing in Swift: {cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning and generative models course, deep learning for coders, deep learning for computer vision, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, github deep learning, intro to deep learning, language processing with deep learning course winter 2019}
- Extra in Swift: {ai and deep learning in 2017, ai degree, cmu deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deeplearning, deeplearning resources, dive into deep learning, learning deep, mit deep learning, siliconvalleydeeplearning, stanford deep learning}

### B4: fuzzy ??rust (overlap 67%)
- Swift: {artificial general intelligence, cpp@>rust, crust of rust, downward thrust, embedded rust, rust, rust lang, rust zh, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Extra in Swift: {cpp@>rust, crust of rust, embedded rust, rust zh}

### B5: fuzzy ??paper (overlap 29%)
- Swift: {agent papers, ai paper, ai paper source, ai papers, autonomous driving, awesome paper, biorxiv/medrxiv/paper, cell papers, cgf paper, chat with paper/paper to blog, chat with pdf/doc/paper, gi-papers, graph paper, how to read paper, how to trace paper, how to write paper, hu-po livestreams on ml papers coding research, ingo wald paper, kesen paper, papers with code}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, livestreams on ml papers coding research, mark papermaster, paper, paper explaine & ??papers explaine & ??paper-reading, paper source, paper to code, papers slop, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Missing in Swift: {awesome.paper, how to finding papers, livestreams on ml papers coding research, mark papermaster, paper, paper explaine & ??papers explaine & ??paper-reading, paper source, paper to code, papers slop, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Extra in Swift: {agent papers, ai paper source, ai papers, awesome paper, biorxiv/medrxiv/paper, cell papers, chat with paper/paper to blog, chat with pdf/doc/paper, graph paper, hu-po livestreams on ml papers coding research, kesen paper}

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

### F1: case-insensitive "vibe coding" (overlap 60%)
- Swift: {coding tech talks, vibe coding, vibe design}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {guide to vibe coding, vibe coding flow/流程/skill}

### F2: alias probe "gpt-4" (overlap 11%)
- Swift: {chat with ai/bloomberggpt, chat with marketinggpt, chatgpt, chatgpt api, chatgpt coding, chatgpt executor, chatgpt for wechat/chat with ai, gpt, gpt 4, gpt-3}
- Python: {agi by gpt-7, autogpt, bloomberggpt, chatgpt, chatgpt at sv code campfire, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin}
- Missing in Swift: {agi by gpt-7, autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin}
- Extra in Swift: {chat with ai/bloomberggpt, chat with marketinggpt, chatgpt api, chatgpt coding, chatgpt for wechat/chat with ai, gpt, gpt 4, gpt-3}

### F3: category ref "#AI" (overlap 44%)
- Swift: {ai, ai engineer, ai model, ai paper, ai programming, ai project, ai-library, berkeley ai, blackshark ai, chat with ai, cmu ai, facebook ai, game ai, grok ai, multimodal ai, personalized ai, pony ai, stanford ai, state of ai}
- Python: {ai, ai anime/ai 动画, ai engineer, ai model, ai paper, ai programming, ai project, ai scraping/chat with crawler, ai-library, aigc, baidu cloud, facebook ai, grok ai, mit csail, multimodal ai, stanford ai, state of ai, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Missing in Swift: {ai anime/ai 动画, ai scraping/chat with crawler, aigc, baidu cloud, mit csail, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Extra in Swift: {berkeley ai, blackshark ai, chat with ai, cmu ai, game ai, personalized ai, pony ai}

### G1: meta AI Model (overlap 78%)
- Swift: {ai workspace, ai2api, aigc, alibaba qwen, anthropic claude, data center, deepseek, doubao, github, grok ai, hugging face, intelligent agent, linux do, mcp, microsoft copilot, openai, reverse engineering, searchin, skywork, web developer, ...+2}
- Python: {aigc, alibaba qwen, anthropic claude, deepseek, doubao, github, grok ai, hugging face, intelligent agent, microsoft copilot, openai, searchin, website, youtube}
- Extra in Swift: {ai workspace, ai2api, data center, linux do, mcp, reverse engineering, skywork, web developer}

### G2: meta Vibe Coding (overlap 61%)
- Swift: {agent computer interface, agent skills, ai model, ai programming, alibaba qwen, andrej karpathy, anthropic claude, augment code, awesome star, bolt new, code generation, code reading, codex cli, command, command-line interface, crush, cursor editor, discord, forge code, github, ...+33}
- Python: {ai model, ai programming, andrej karpathy, anthropic claude, code generation, command, discord, github, github copilot, google gemini, input method, intelligent agent, openai, reddit, searchin, website, y-playlist, y-video, youtube}
- Extra in Swift: {agent computer interface, agent skills, alibaba qwen, augment code, awesome star, bolt new, code reading, codex cli, command-line interface, crush, cursor editor, forge code, github inc, google antigravity, grok ai, kimi ai, kiro, low code, mcp, minimax ai, ...+14}

### G4: meta Docker (overlap 50%)
- Swift: {}
- Python: {website}
- Missing in Swift: {website}

## Skipped
- E2 community peers of AI Model: community divergent (overlap 3%); py=99 swift=50

