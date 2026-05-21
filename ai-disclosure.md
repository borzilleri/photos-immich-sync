# AI Usage Disclosure

This project was developed with assistance from AI agents (Cursor and Claude 
Code, specifically).

* Core logic & code interacting with PhotoKit and Immich was written by me 
  (a human).

* AI Agents wrote some accessory/helper code: resiliency methods (retries, 
  timeouts), caching, and SQLite querying. Largely because I'm still fairly
  new to swift and I'm still working to wrap my head around the way it wants
  to implement these, syntactically and semantically.

* AI Agents wrote the files in the [scripts](./scripts/) directory, because to 
  be perfectly honest: getting building, packaging, and notarizing correct is
  a fucking hassle.

* AI Agents were used to review the codebase, identify bugs and potential
  issues, and recommend solutions. It was used to aid in the design and planning
  of fixes and features. Except where noted above, code changes were
  subsequently written by me (somehow, still a human).

* In all cases where an AI agent wrote code it was designed first in a planning
  mode, and I reviewed the plan to ensure the changes were understood and 
  intended. The resulting code was also manually reviewed by me (still a human)
  and is, to the best of my ability to determine, correct. (Or, at least,
  intended; it could still be incorrect and I'm just dumb.)

* Documentation. _sigh_. I hate writing documentation. I used AI agents to 
  put together the initial version many sections in the README, and then 
  (painstakingly) went through to edit the text to ensure it was correct, and
  said what I wanted to in the way I wanted to. But you can probably see
  some of it's mannerisms remain. Sorry.