Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build of product 'xlb-diff' complete! (0.12s)
[xlb-diff] syncing Swift index...
[xlb-diff] sync: no-op (index already fresh)
[FAIL] A1: exact "AI Model" (overlap 0%)
[FAIL] A2: exact "Vibe Coding" (overlap 15%)
[FAIL] A3: exact "Awesome Search" (overlap 5%)
[FAIL] A4: exact "Deep Learning" (overlap 11%)
[FAIL] A5: exact "MCP" (overlap 50%)
[FAIL] A6: substring "vibe cod" (overlap 5%)
[FAIL] A7: substring "deep lea" (overlap 11%)
[FAIL] A8: substring "awesome" (overlap 11%)
[FAIL] A9: substring "model" (overlap 11%)
[FAIL] A10: substring "docker" (overlap 18%)
[FAIL] B1: fuzzy ??vibe (overlap 29%)
[FAIL] B2: fuzzy ??deep learning (overlap 14%)
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
2026-08-02 16:00:24.991 xlb-diff[1234:1041265] [XLBTopicIndex] graphCommunity converged in 20 iteration(s), 85 clusters (>= 2)
[SKIP] E2: community peers of AI Model - community divergent (overlap 1%); py=99 swift=50
[FAIL] F1: case-insensitive "vibe coding" (overlap 15%)
[FAIL] F2: alias probe "gpt-4" (overlap 5%)
[FAIL] F3: category ref "#AI" (overlap 5%)
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
### A1: exact "AI Model" (overlap 0%)
- Swift: {ai, ai model, aicg, aidl, aigc, aiml, aiot, bair, fail, 降ai率}
- Python: {ai engineer, ai-library, berkeley ai, blockchain, facebook ai, google brain, mit csail, sony interactive entertainment, stanford ai, state of ai}
- Missing in Swift: {ai engineer, ai-library, berkeley ai, blockchain, facebook ai, google brain, mit csail, sony interactive entertainment, stanford ai, state of ai}
- Extra in Swift: {ai, ai model, aicg, aidl, aigc, aiml, aiot, bair, fail, 降ai率}

### A2: exact "Vibe Coding" (overlap 15%)
- Swift: {ai coding, coding, coding tech, coding tools, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {coding tech talks, guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tech, coding tools, decoding, vibe, vibe/转录, vibeshell}

### A3: exact "Awesome Search" (overlap 5%)
- Swift: {ai search, api search, awesome, awesome research, awesome search, bt search, research, search, 活动search, 表情包search}
- Python: {awesome, bing search, code search, how to do research, how to search, job search, music search, nvidia research, personalized search, snapshot search}
- Missing in Swift: {bing search, code search, how to do research, how to search, job search, music search, nvidia research, personalized search, snapshot search}
- Extra in Swift: {ai search, api search, awesome research, awesome search, bt search, research, search, 活动search, 表情包search}

### A4: exact "Deep Learning" (overlap 11%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, nvidia deep learning institute, stanford deep learning}
- Python: {ai and deep learning in 2017, cs230 deep learning autumn 2018, cs330 deep multi-task and meta learning autumn 2020, deep learning and generative models course, deep learning book, deep learning for games, deep learning framework, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, siliconvalleydeeplearning}
- Missing in Swift: {ai and deep learning in 2017, cs230 deep learning autumn 2018, cs330 deep multi-task and meta learning autumn 2020, deep learning and generative models course, deep learning for games, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, siliconvalleydeeplearning}
- Extra in Swift: {deep learning, deep learning for coder, deep learning for natural language processing, deep learning for nlp, dive into deep learning, mit deep learning, nvidia deep learning institute, stanford deep learning}

### A5: exact "MCP" (overlap 50%)
- Swift: {mcp, mcp client, mcp server, mcp servers, mcp/skill, skill/mcp}
- Python: {an mcp server to run applescript and jxa, api to mcp, mcp, mcp client, mcp server, mcp/skill}
- Missing in Swift: {an mcp server to run applescript and jxa, api to mcp}
- Extra in Swift: {mcp servers, skill/mcp}

### A6: substring "vibe cod" (overlap 5%)
- Swift: {catcode, code, codecs, codex, coding, nocode, vibe, vibe coding, vscode, xcode}
- Python: {code editor, code encryption, code instrumentation, code obfuscation, code reading, coding tech talks, how code run, source code leak, vibe coding flow/流程/skill, xcode}
- Missing in Swift: {code editor, code encryption, code instrumentation, code obfuscation, code reading, coding tech talks, how code run, source code leak, vibe coding flow/流程/skill}
- Extra in Swift: {catcode, code, codecs, codex, coding, nocode, vibe, vibe coding, vscode}

### A7: substring "deep lea" (overlap 11%)
- Swift: {deep learning, deep learning book, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, nvidia deep learning institute, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, deep learning, deep learning and generative models course, deep learning book, deep learning i spring 2024 i professor christopher manning, deep learning indaba, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl}
- Missing in Swift: {ai and deep learning in 2017, ai degree, deep learning and generative models course, deep learning i spring 2024 i professor christopher manning, deep learning indaba, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl}
- Extra in Swift: {deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, dive into deep learning, mit deep learning, nvidia deep learning institute, stanford deep learning}

### A8: substring "awesome" (overlap 11%)
- Swift: {awesome, awesome ai, awesome deploy, awesome iptv, awesome list, awesome lists, awesome nerf, awesome paper, awesome star, awesomeness}
- Python: {awesome, awesome list/repo sort, awesome searc, awesome search, awesome searh, awesome star, awesome.paper, awesome//:combine, curated list of awesome things regarding webassembly, mfatihmar/awesome-game-networking project:spatialos}
- Missing in Swift: {awesome list/repo sort, awesome searc, awesome search, awesome searh, awesome.paper, awesome//:combine, curated list of awesome things regarding webassembly, mfatihmar/awesome-game-networking project:spatialos}
- Extra in Swift: {awesome ai, awesome deploy, awesome iptv, awesome list, awesome lists, awesome nerf, awesome paper, awesomeness}

### A9: substring "model" (overlap 11%)
- Swift: {language model, model, model 3, model context protocol, modeling, models, models in, multimodal model, probabilistic graphical model, probabilistic graphical models}
- Python: {ai model, artificial general intelligence, artificial intelligence, energy-based model, language model, model context protocol, score-based generative model, spiral model, v-model, viewmodel}
- Missing in Swift: {ai model, artificial general intelligence, artificial intelligence, energy-based model, score-based generative model, spiral model, v-model, viewmodel}
- Extra in Swift: {model, model 3, modeling, models, models in, multimodal model, probabilistic graphical model, probabilistic graphical models}

### A10: substring "docker" (overlap 18%)
- Swift: {docker hub, docker ide, docker image, docker images, docker root, docker series, docker.org, docker@>lxc, docker瘦身, docker管理}
- Python: {android run docker, docker, docker ecosystem, docker hub, docker inspect, docker-series, docker瘦身, docker管理, github:docker, play with docker/playground}
- Missing in Swift: {android run docker, docker, docker ecosystem, docker inspect, docker-series, github:docker, play with docker/playground}
- Extra in Swift: {docker ide, docker image, docker images, docker root, docker series, docker.org, docker@>lxc}

### B1: fuzzy ??vibe (overlap 29%)
- Swift: {streaming tts/realtime tts/vibevoice, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {guide to vibe coding, relaxing vibe, south korea vibe walk, streaming tts/realtime tts/vibevoice, vacation vibes driving india, vibe, vibe coding, vibe coding flow/流程/skill, vibe design, vibe gaming, vibecodefixers, vibes}
- Missing in Swift: {guide to vibe coding, relaxing vibe, south korea vibe walk, vacation vibes driving india, vibe coding flow/流程/skill, vibe gaming, vibecodefixers, vibes}
- Extra in Swift: {vibe/转录, vibeshell}

### B2: fuzzy ??deep learning (overlap 14%)
- Swift: {ai and deep learning in 2017, cmu deep learning, deep learning, deep learning book, deep learning for coder, deep learning for games, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep learning indaba, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, dive into deep learning, github deep learning, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, stanford deep learning}
- Python: {ai and deep learning in 2017, ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs330 deep multi-task and meta learning autumn 2020, deep learning, deep learning and generative models course, deep learning book, deep learning for coders, deep learning for computer vision, deep learning for games, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, deep learning indaba, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Missing in Swift: {ai degree, cs224n natural language processing with deep learning 2023, cs230 deep learning autumn 2018, cs230 deep learning i autumn 2025, cs330 deep multi-task and meta learning autumn 2020, deep learning and generative models course, deep learning for coders, deep learning for computer vision, deep learning i spring 2024 i professor christopher manning, deep learning i2dl 2020, deep learning i2dl 2023, deep reinforcement learning, deeplearning.university, learning course deepmind x ucl, networks and deep learning tutorial with keras and tensorflow}
- Extra in Swift: {cmu deep learning, deep learning for coder, deep learning for natural language processing, deep learning for nlp, deep learning framework, deep learning lecture series 2020 deepmind x ucl, deep learning summer school, deep learning weekly, dive into deep learning, github deep learning, introduction to deep learning, mit deep learning, multimodal deep learning, nvidia deep learning institute, stanford deep learning}

### B4: fuzzy ??rust (overlap 58%)
- Swift: {cpp@>rust, crust of rust, downward thrust, embedded rust, rust, rust lang, rust zh, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Python: {artificial general intelligence, downward thrust, rust, rust lang, rustenburg south africa, the rust programming language book, trust wallet, trustable}
- Missing in Swift: {artificial general intelligence}
- Extra in Swift: {cpp@>rust, crust of rust, embedded rust, rust zh}

### B5: fuzzy ??paper (overlap 11%)
- Swift: {ai paper, ai papers, cgf paper, gi-papers, paper explain/summarize, paper explaine, paper list, paper to code, paper to webpage, papers, papers analytics, papers explaine/论文精读, papers for, papers with code, paperwebsite, paperweekly, paper翻译, readpaper, rl papers, wallpaper}
- Python: {ai paper, autonomous driving, awesome.paper, how to read paper, how to trace paper, how to write paper, ingo wald paper, livestreams on ml papers coding research, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper source, paper to code, papers, papers with code, stanford graphics paper, two minute papers, wallpaper engine/live wallpaper/动态壁纸/美化, white papers, 区块链papers}
- Missing in Swift: {autonomous driving, awesome.paper, how to read paper, how to trace paper, how to write paper, ingo wald paper, livestreams on ml papers coding research, paper, paper discussion, paper explaine & ??papers explaine & ??paper-reading, paper source, stanford graphics paper, two minute papers, wallpaper engine/live wallpaper/动态壁纸/美化, white papers, 区块链papers}
- Extra in Swift: {ai papers, cgf paper, gi-papers, paper explain/summarize, paper explaine, paper list, paper to webpage, papers analytics, papers explaine/论文精读, papers for, paperwebsite, paperweekly, paper翻译, readpaper, rl papers, wallpaper}

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
- Swift: {ai coding, coding, coding tech, coding tools, decoding, vibe, vibe coding, vibe design, vibe/转录, vibeshell}
- Python: {coding tech talks, guide to vibe coding, vibe coding, vibe coding flow/流程/skill, vibe design}
- Missing in Swift: {coding tech talks, guide to vibe coding, vibe coding flow/流程/skill}
- Extra in Swift: {ai coding, coding, coding tech, coding tools, decoding, vibe, vibe/转录, vibeshell}

### F2: alias probe "gpt-4" (overlap 5%)
- Swift: {chatgpt, gpt, gpt 3, gpt 4, gpt store, gpt-3, gpt4, gptk, gpts, nanogpt}
- Python: {autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt, dive into llms like chatgpt, gpt-3, 解锁newbing/chatgpt机场}
- Missing in Swift: {autogpt, bloomberggpt, chatgpt at sv code campfire, chatgpt prompt, code interpreter/code gen/gpt plugin, deep dive into llms like chatgpt, detect gpt, dive into llms like chatgpt, 解锁newbing/chatgpt机场}
- Extra in Swift: {chatgpt, gpt, gpt 3, gpt 4, gpt store, gpt4, gptk, gpts, nanogpt}

### F3: category ref "#AI" (overlap 5%)
- Swift: {ai, ai agent, ai degree, ai researcher, ai vs art, ai vs baby, ai vs dcc, aigc, ai人才地图, ai即工具, bair, brain vs symbol, burn vs brainwash, chain reaction, explain vs explain, how brain thinking, internet vs brain, point to line to trajectory to reincarnation to evolution to beyond to faith, solve grail, solve uncertainty}
- Python: {ai, ai anime/ai 动画, ai engineer, ai paper, ai project, ai-library, aigc, domain language, facebook ai, game ai engine, google gmail, grok ai, mit csail, multimodal ai, sony interactive entertainment, stanford ai, state of ai, the blockchain, top ai influencers on x, 换脸/roop/deepfake/deepface/ai face}
- Missing in Swift: {ai anime/ai 动画, ai engineer, ai paper, ai project, ai-library, domain language, facebook ai, game ai engine, google gmail, grok ai, mit csail, multimodal ai, sony interactive entertainment, stanford ai, state of ai, the blockchain, top ai influencers on x, 换脸/roop/deepfake/deepface/ai face}
- Extra in Swift: {ai agent, ai degree, ai researcher, ai vs art, ai vs baby, ai vs dcc, ai人才地图, ai即工具, bair, brain vs symbol, burn vs brainwash, chain reaction, explain vs explain, how brain thinking, internet vs brain, point to line to trajectory to reincarnation to evolution to beyond to faith, solve grail, solve uncertainty}

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
- E2 community peers of AI Model: community divergent (overlap 1%); py=99 swift=50

