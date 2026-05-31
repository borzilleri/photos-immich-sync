# AI Usage Disclosure

This project was developed with assistance from AI agents (Cursor and Claude 
Code, specifically).

* Core logic & code interacting with PhotoKit and Immich was written by me 
  (a human).

* AI Agents wrote some accessory/helper code: resiliency methods (retries, 
  timeouts), caching, logging, and SQLite querying. In part, because I'm still
  fairly new to swift and I'm working to understand its idioms. And in part,
  because a lot of it is boilerplate bullshit that I don't want to spend cycles
  on.

* AI Agents wrote the files in the [scripts](./scripts/) directory, because to 
  be perfectly honest: getting building, packaging, and notarizing correct is
  a fucking hassle.

* AI Agents were used to perform code reviews and identify bugs, potential
  issues, and code smells. In some cases it was used to aid in the design of
  fixes for those issues. Except where noted above, subsequent code changes
  were implemented by me (somehow, still a human).

* In all cases where an AI agent wrote code it was designed first in a planning
  mode, and I reviewed the plan to ensure the changes were understood and 
  intended. The resulting code was also manually reviewed by me (astonishly, 
  still a human) and is, to the best of my ability to determine, correct. 
  (Or, at least, intended; it could still be incorrect and I'm just dumb.)

* Documentation. _sigh_. I hate writing documentation. I used AI agents to 
  put together the initial version of many sections in the README. I then 
  (painstakingly) went through to edit the text to ensure it was correct and
  said what I wanted to say, in the way I wanted to say it. But you can probably
  still see some of it's mannerisms. I hate them too. Maybe i'll do another
  edit pass in the future.
