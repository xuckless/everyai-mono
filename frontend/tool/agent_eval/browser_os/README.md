# Browser OS: a harness check

A long, open-ended task that exercises a harness's automatic tool use,
planning, verification and subagents. It is graded by people, not a script.

How to run it:

1. Create an empty folder, `git init` it and make one commit (so Changes
   works), then add it as a Code project.
2. Start a session with **Sonnet 5.5 · Medium** and **Full auto**, once with
   the harness set to **OpenHands** and once with **EveryAI** (the agent
   menu's Harness page on the New session screen). Paste `TASK.md` as the
   first message. Use a separate folder for each run.
3. When each run ends, use **Export transcript…** in the session's menu.
4. Compare the two `index.html` files in Chrome and the two transcripts: the
   tools used and how, the flow (plans, todo list, questions asked, forks),
   whether it checked its own work, cost and time.
