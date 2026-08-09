Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
2026-08-03 16:13:19.441 xlb-diff[40494:1369851] [XLBTopicIndex] parsed 341 records / 26319 topics / 27114 edges from 39 files in 30.922s
[xlb-diff] sync ok: 341 records / 26319 topics / 27114 edges in 30.92s
[FAIL] A1: exact "AI Model" (overlap 82%)
[PASS] A2: exact "Vibe Coding" (overlap 100%)
[PASS] A3: exact "Awesome Search" (overlap 90%)
[FAIL] A4: exact "Deep Learning" (overlap 25%)
[FAIL] A5: exact "MCP" (overlap 83%)
[FAIL] A6: substring "vibe cod" (overlap 82%)
[FAIL] A7: substring "deep lea" (overlap 25%)
[FAIL] A8: substring "awesome" (overlap 58%)
[FAIL] A9: substring "model" (overlap 73%)
[FAIL] A10: substring "docker" (overlap 33%)
[FAIL] B1: fuzzy ??vibe (overlap 75%)
[FAIL] B2: fuzzy ??deep learning (overlap 38%)
[PASS] B3: fuzzy ??cursor (overlap 100%)
[FAIL] B4: fuzzy ??rust (overlap 80%)
[FAIL] B5: fuzzy ??paper (overlap 22%)
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
[SKIP] E2: community peers of AI Model - community divergent (overlap 12%); py=99 swift=50
[PASS] F1: case-insensitive "vibe coding" (overlap 100%)
[FAIL] F2: alias probe "gpt-4" (overlap 25%)
[PASS] F3: category ref "#AI" (overlap 90%)
[PASS] G1: meta AI Model (overlap 100%)
[PASS] G2: meta Vibe Coding (overlap 100%)
[PASS] G3: meta Deep Learning (overlap 97%)
[PASS] G4: meta Docker (overlap 100%)
[PASS] G5: meta MCP (overlap 90%)
# xlb differential test report

## Summary
- Total: 35
- Passed: 18
- Failed: 16
- Skipped: 1

## Failures
### A1: exact "AI Model" (overlap 82%)
- Swift: {ai degree, ai model, ai paper, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Python: {ai degree, ai model, ai-library, aigc, baidu cloud, mit csail, openai-compatible models, stanford ai, state of ai, world model}
- Missing in Swift: {ai-library}
- Extra in Swift: {ai paper}

### A4: exact "Deep Learning" (overlap 25%)
- Swift: {cmu deep learning, deep learning, deep learning for coder, deep learning for nlp, deep learning framework, deep learning lecture series 2020 deepmind x ucl, deep reinforcement learning, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, deep learning, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {ai and deep learning in 2017, deep learning book, deep learning for computer vision, deeplearning.university, github deep learning, stanford deep learning}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for nlp, deep learning lecture series 2020 deepmind x ucl, dive into deep learning, mit deep learning}

### A5: exact "MCP" (overlap 83%)
- Swift: {an mcp server to run applescript and jxa, mcp, mcp client, mcp server, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, mcp, mcp client, mcp server, mcp/skill}
- Extra in Swift: {skill/mcp}

### A6: substring "vibe cod" (overlap 82%)
- Swift: {code generation, code instrumentation, code reading, code visualization, coding tech talks, vibe coding, vibe coding flow/流程/skill, vibe design, vibecodefixers, vscode}
- Python: {code generation, code instrumentation, code reading, code visualization, coding tech talks, papers with code, vibe coding, vibe coding flow/流程/skill, vibecodefixers, vscode}
- Missing in Swift: {papers with code}
- Extra in Swift: {vibe design}

### A7: substring "deep lea" (overlap 25%)
- Swift: {cmu deep learning, deep learning for coder, deep learning for nlp, deep learning framework, deep learning lecture series 2020 deepmind x ucl, deep reinforcement learning, deeplearning.university, dive into deep learning, mit deep learning, siliconvalleydeeplearning}
- Python: {ai and deep learning in 2017, ai degree, deep learning book, deep learning for computer vision, deep learning framework, deep reinforcement learning, deeplearning.university, github deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {ai and deep learning in 2017, ai degree, deep learning book, deep learning for computer vision, github deep learning, stanford deep learning}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for nlp, deep learning lecture series 2020 deepmind x ucl, dive into deep learning, mit deep learning}

### A8: substring "awesome" (overlap 58%)
- Swift: {awesome, awesome harmonyos, awesome roadmaps, awesome sea, awesome searc, awesome search, awesome searh, awesome star, mfatihmar/awesome-game-networking project:spatialos}
- Python: {awesome, awesome sea, awesome searc, awesome search, awesome searh, awesome star, awesome-library, awesome.paper, awesome//:combine, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome-library, awesome.paper, awesome//:combine}
- Extra in Swift: {awesome harmonyos, awesome roadmaps}

### A9: substring "model" (overlap 73%)
- Swift: {3d model, 3d model synthesis, ai model, diffusion probabilistic models, github models, model, model synthesis, models, world model}
- Python: {3d model, 3d model synthesis, ai model, cesm community earth system model, chaos model, diffusion probabilistic models, github models, model, model synthesis, world model}
- Missing in Swift: {cesm community earth system model, chaos model}
- Extra in Swift: {models}

### A10: substring "docker" (overlap 33%)
- Swift: {android run docker, docker ide, docker server, docker-series, docker.org, docker/replit deploy, docker@>lxc, docker管理, github:docker, pod1@>pod2@>docker@>kubelet@>kube-proxy@>fluentd@>dns@>ui}
- Python: {android run docker, docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile, docker-series, docker/replit deploy, docker管理, github:docker}
- Missing in Swift: {docker, docker desktop, docker ecosystem, docker hub, docker image to dockerfile}
- Extra in Swift: {docker ide, docker server, docker.org, docker@>lxc, pod1@>pod2@>docker@>kubelet@>kube-proxy@>fluentd@>dns@>ui}

### B1: fuzzy ??vibe (overlap 75%)
- Swift: {south korea vibe walk, streaming tts/realtime tts/vibevoice, vibe coding, vibe coding flow/流程/skill, vibe design, vibe/转录, vibecodefixers, vibeshell}
- Python: {south korea vibe walk, streaming tts/realtime tts/vibevoice, vibe coding, vibe coding flow/流程/skill, vibe design, vibecodefixers}
- Extra in Swift: {vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 38%)
- Swift: {ai and deep learning in 2017, ai degree, cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for nlp, deep learning framework, deep learning lecture series 2020 deepmind x ucl, deep reinforcement learning, deeplearning.university, dive into deep learning, github deep learning, intro to deep learning and generative models course, introduction to deep learning, mit deep learning, silicon valley deep learning group, siliconvalleydeeplearning, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, deep learning, deep learning book, deep learning for computer vision, deep learning for games, deep learning for natural language processing, deep learning framework, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, deep reinforcement learning, deeplearning.university, dive into deep learning book, github deep learning, machine learning, mit 6.s191 introduction to deep learning, siliconvalleydeeplearning, stanford deep learning}
- Missing in Swift: {deep learning for computer vision, deep learning for natural language processing, deep learning indaba, deep learning specialization, deep learning summer school, deep learning weekly, dive into deep learning book, machine learning, mit 6.s191 introduction to deep learning}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for nlp, deep learning lecture series 2020 deepmind x ucl, dive into deep learning, intro to deep learning and generative models course, introduction to deep learning, mit deep learning, silicon valley deep learning group}

### B4: fuzzy ??rust (overlap 80%)
- Swift: {artificial general intelligence, cpp@>rust, crust of rust, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Extra in Swift: {cpp@>rust, crust of rust}

### B5: fuzzy ??paper (overlap 22%)
- Swift: {ai paper, ai paper source, awesome.paper, biorxiv/medrxiv/paper, chat with paper/paper to blog, chat with pdf/doc/paper, graph paper, hu-po livestreams on ml papers coding research, kesen paper, key papers, paper explain/summarize, paper explaine & ??papers explaine & ??paper-reading, paper to code, paper to webpage, papers, papers analytics, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Python: {ai paper, autonomous driving, awesome.paper, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, mark papermaster, minute papers, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper reading club, papers, papers with code, wallpaper engine/live wallpaper/动态壁纸/美化, 壁纸/wallpaper}
- Missing in Swift: {autonomous driving, cgf paper, gi-papers, how to finding papers, how to read paper, how to trace paper, how to write paper, ingo wald paper, mark papermaster, minute papers, paper, paper discussion, paper reading club}
- Extra in Swift: {ai paper source, biorxiv/medrxiv/paper, chat with paper/paper to blog, chat with pdf/doc/paper, graph paper, hu-po livestreams on ml papers coding research, kesen paper, key papers, paper explain/summarize, paper to code, paper to webpage, papers analytics}

### C2: path Vibe Coding -> LLM (overlap 0%)
- Swift: {Vibe Coding, Intelligent Agent, Meta Guide, llm}
- Python: {}
- Extra in Swift: {Vibe Coding, Intelligent Agent, Meta Guide, llm}

### D3: explore PyTorch hops=2 (overlap 86%)
- Swift: {ai paper, alfredo canziani, andrew ng, jeremy howard, lex fridman, mlcourse ai}
- Python: {ai paper, alfredo canziani, andrew ng, jeremy howard, lex fridman, mlcourse ai, ng}
- Missing in Swift: {ng}

### D4: explore Docker hops=1 (overlap 0%)
- Swift: {}
- Python: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}
- Missing in Swift: {cncf map, devops, flexible extension, google cloud platform, kubernetes, linux system, macos, nas hard drive, online ide, paas, remote control, sandbox, self-hosting service, service deploy, system monitoring, twoyi, virtual machine, webassembly, workflow automation}

### F2: alias probe "gpt-4" (overlap 25%)
- Swift: {agi by gpt-7, autogpt, chat with ai/bloomberggpt, chat with marketinggpt, chatgpt, chatgpt coding, chatgpt executor, chatgpt for wechat/chat with ai, gpt-3, gptk}
- Python: {agi by gpt-7, autogpt, chatgpt, chatgpt executor, chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt}
- Missing in Swift: {chatgpt midjourney elevenlabs d-id, chatgpt plus注册, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt}
- Extra in Swift: {chat with ai/bloomberggpt, chat with marketinggpt, chatgpt coding, chatgpt for wechat/chat with ai, gpt-3, gptk}

## Skipped
- E2 community peers of AI Model: community divergent (overlap 12%); py=99 swift=50

