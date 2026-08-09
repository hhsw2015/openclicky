Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.11s)
[xlb-diff] syncing Swift index...
2026-08-02 17:46:00.665 xlb-diff[80070:1296775] [XLBTopicIndex] parsed 341 records / 32072 topics / 29769 edges from 39 files in 21.316s
[xlb-diff] sync ok: 341 records / 32072 topics / 29769 edges in 21.32s
[FAIL] A1: exact "AI Model" (overlap 43%)
[FAIL] A2: exact "Vibe Coding" (overlap 25%)
[FAIL] A3: exact "Awesome Search" (overlap 54%)
[FAIL] A4: exact "Deep Learning" (overlap 11%)
[FAIL] A5: exact "MCP" (overlap 50%)
[FAIL] A6: substring "vibe cod" (overlap 33%)
[FAIL] A7: substring "deep lea" (overlap 5%)
[FAIL] A8: substring "awesome" (overlap 18%)
[FAIL] A9: substring "model" (overlap 33%)
[FAIL] A10: substring "docker" (overlap 11%)
[FAIL] B1: fuzzy ??vibe (overlap 29%)
[FAIL] B2: fuzzy ??deep learning (overlap 8%)
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
2026-08-02 17:46:15.456 xlb-diff[80070:1296776] [XLBTopicIndex] graphCommunity(Louvain) converged in 21 pass iteration(s), Q=0.8576, 46 clusters (>= 2), 0.797s
[SKIP] E2: community peers of AI Model - community divergent (overlap 3%); py=99 swift=50
[FAIL] F1: case-insensitive "vibe coding" (overlap 25%)
[FAIL] F2: alias probe "gpt-4" (overlap 5%)
[FAIL] F3: category ref "#AI" (overlap 29%)
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
### A1: exact "AI Model" (overlap 43%)
- Swift: {ai model, ai paper, aigc, baidu cloud, mit csail, spain city list, stanford ai, state of ai, thailand city list, world longest railways}
- Python: {ai degree, ai model, ai-library, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Missing in Swift: {ai degree, ai-library, openai-compatible models, world model}
- Extra in Swift: {ai paper, spain city list, thailand city list, world longest railways}

### A2: exact "Vibe Coding" (overlap 25%)
- Swift: {ai coding, coding, coding tech, coding tech talks, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tech, decoding, vibe, vibe/转录, vibeshell}

### A3: exact "Awesome Search" (overlap 54%)
- Swift: {awesome research, awesome search, google search, how to do research, microsoft research, net disk search, search, social search, subscription search, vertical search}
- Python: {awesome search, google search, how to do research, microsoft research, net disk search, research-library, search engine, social search, vertical search, 搜索引擎 project:google search}
- Missing in Swift: {research-library, search engine, 搜索引擎 project:google search}
- Extra in Swift: {awesome research, search, subscription search}

### A4: exact "Deep Learning" (overlap 11%)
- Swift: {cmu deep learning, deep learning, deep learning for games, deep learning for natural language processing, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, github deep learning, nvidia deep learning institute}
- Python: {cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, networks and deep learning tutorial with keras and tensorflow}
- Missing in Swift: {cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, networks and deep learning tutorial with keras and tensorflow}
- Extra in Swift: {cmu deep learning, deep learning for games, deep learning for natural language processing, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, nvidia deep learning institute}

### A5: exact "MCP" (overlap 50%)
- Swift: {mcp, mcp client, mcp server, mcp servers, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, api to mcp, mcp, mcp client, mcp server, mcp/skill}
- Missing in Swift: {an mcp server to run applescript and jxa, api to mcp}
- Extra in Swift: {mcp servers, skill/mcp}

### A6: substring "vibe cod" (overlap 33%)
- Swift: {code generation, code reading, code search, code visualization, low code, papers with code, source code, vibe coding, vibe design, vscode}
- Python: {code generation, code instrumentation, code reading, coding tech talks, guide to vibe coding, papers with code, vibe coding, vibe coding flow/流程/skill, vibecodefixers, vscode}
- Missing in Swift: {code instrumentation, coding tech talks, guide to vibe coding, vibe coding flow/流程/skill, vibecodefixers}
- Extra in Swift: {code search, code visualization, low code, source code, vibe design}

### A7: substring "deep lea" (overlap 5%)
- Swift: {cmu deep learning, deep learning, deep learning for games, deep learning for natural language processing, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, github deep learning, nvidia deep learning institute}
- Python: {cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, learning course deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Missing in Swift: {cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Extra in Swift: {cmu deep learning, deep learning, deep learning for games, deep learning for natural language processing, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, nvidia deep learning institute}

### A8: substring "awesome" (overlap 18%)
- Swift: {awesome, awesome ai, awesome ar, awesome game engine, awesome gaussian splatting, awesome graphics, awesome mr, awesome search, awesome star, awesome vr}
- Python: {awesome, awesome sea, awesome searc, awesome search, awesome searh, awesome star, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome sea, awesome searc, awesome searh, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Extra in Swift: {awesome ai, awesome ar, awesome game engine, awesome gaussian splatting, awesome graphics, awesome mr, awesome vr}

### A9: substring "model" (overlap 33%)
- Swift: {3d model synthesis, ai model, cloudflare models, github models, language model, language models, model, model 3, models, world model}
- Python: {3d model, 3d model synthesis, ai model, cesm community earth system model, chaos model, diffusion probabilistic models, github models, model, model synthesis, world model}
- Missing in Swift: {3d model, cesm community earth system model, chaos model, diffusion probabilistic models, model synthesis}
- Extra in Swift: {cloudflare models, language model, language models, model 3, models}

### A10: substring "docker" (overlap 11%)
- Swift: {docker compose, docker hub, docker ide, docker image, docker root, docker series, docker server, docker.org, docker/replit deploy, docker@>lxc}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker-series, docker/replit deploy, docker管理, github:docker}
- Missing in Swift: {android run docker, docker, docker desktop, docker ecosystem, docker image to dockerfile, docker-series, docker管理, github:docker}
- Extra in Swift: {docker compose, docker ide, docker image, docker root, docker series, docker server, docker.org, docker@>lxc}

### B1: fuzzy ??vibe (overlap 29%)
- Swift: {streaming tts/realtime tts/vibevoice, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {guide to vibe coding, relaxing vibe, south korea vibe walk, streaming tts/realtime tts/vibevoice, vacation vibes driving india, vibe, vibe coding, vibe coding flow/流程/skill, vibe design, vibe gaming, vibecodefixers, vibes}
- Missing in Swift: {guide to vibe coding, relaxing vibe, south korea vibe walk, vacation vibes driving india, vibe coding flow/流程/skill, vibe gaming, vibecodefixers, vibes}
- Extra in Swift: {vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 8%)
- Swift: {cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, github deep learning, intro to deep learning and generative models course, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, silicon valley deep learning group, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning, deep learning and generative models course, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, learning course deepmind x ucl, learning lecture series 2020 deepmind x ucl, networks and deep learning tutorial with keras and tensorflow, siliconvalleydeeplearning}
- Missing in Swift: {ai and deep learning in 2017, ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs231n deep learning for computer vision i 2025, cs330 deep multi-task and meta learning, cs330 deep multi-task and meta learning autumn 2020, cs330 deep multi-task and meta learning i autumn 2022, deep learning and generative models course, deep learning for computer vision, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl, learning lecture series 2020 deepmind x ucl, networks and deep learning tutorial with keras and tensorflow, siliconvalleydeeplearning}
- Extra in Swift: {cmu deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, intro to deep learning and generative models course, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, silicon valley deep learning group, stanford deep learning}

### B4: fuzzy ??rust (overlap 58%)
- Swift: {cpp@>rust, crust of rust, downward thrust, embedded rust, rust, rust lang, rust zh, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Missing in Swift: {artificial general intelligence}
- Extra in Swift: {cpp@>rust, crust of rust, embedded rust, rust zh}

### B5: fuzzy ??paper (overlap 11%)
- Swift: {ai paper, ai papers, cgf paper, gi-papers, paper explain/summarize, paper explaine, paper list, paper to code, paper to webpage, papers, papers analytics, papers explaine/论文精读, papers for, papers with code, paperwebsite, paperweekly, paper翻译, readpaper, rl papers, wallpaper}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, livestreams on ml papers coding research, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Missing in Swift: {autonomous driving, awesome.paper, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, livestreams on ml papers coding research, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Extra in Swift: {ai papers, paper explain/summarize, paper explaine, paper list, paper to code, paper to webpage, papers, papers analytics, papers explaine/论文精读, papers for, paperwebsite, paperweekly, paper翻译, readpaper, rl papers, wallpaper}

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

### F1: case-insensitive "vibe coding" (overlap 25%)
- Swift: {ai coding, coding, coding tech, coding tech talks, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tech, decoding, vibe, vibe/转录, vibeshell}

### F2: alias probe "gpt-4" (overlap 5%)
- Swift: {chatgpt, detect gpt, gpt, gpt 3, gpt 4, gpt store, gpt-3, gpt4, gpts, nanogpt}
- Python: {agi by gpt-7, autogpt, bloomberggpt, chatgpt, chatgpt at sv code campfire, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin}
- Missing in Swift: {agi by gpt-7, autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin}
- Extra in Swift: {detect gpt, gpt, gpt 3, gpt 4, gpt store, gpt-3, gpt4, gpts, nanogpt}

### F3: category ref "#AI" (overlap 29%)
- Swift: {ai, ai degree, ai model, ai paper, ai programming, aifromscratch, aigc, baidu cloud, blockchain, google brain, google gmail, mit csail, openai, sony interactive entertainment, spain city list, stanford ai, state of ai, thailand city list, the blockchain, world longest railways}
- Python: {ai, ai anime/ai 动画, ai engineer, ai model, ai paper, ai programming, ai project, ai scraping/chat with crawler, ai-library, aigc, baidu cloud, facebook ai, grok ai, mit csail, multimodal ai, stanford ai, state of ai, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Missing in Swift: {ai anime/ai 动画, ai engineer, ai project, ai scraping/chat with crawler, ai-library, facebook ai, grok ai, multimodal ai, top ai influencers on x, 图像修复/image restoration/ai修复/ai restor, 换脸/roop/deepfake/deepface/ai face}
- Extra in Swift: {ai degree, aifromscratch, blockchain, google brain, google gmail, openai, sony interactive entertainment, spain city list, thailand city list, the blockchain, world longest railways}

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

