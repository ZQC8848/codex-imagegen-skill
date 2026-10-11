---
name: codex-imagegen
description: Generate or edit images by delegating to Codex CLI's built-in image generation (gpt-image), including transparent PNGs via solid-color background plus chroma keying. Use when the user asks to generate, draw, design, or edit an image, icon, sprite, texture, concept art, illustration, banner, character sheet, UI asset, or placeholder art - in Chinese (生图、画一张、生成图片、做个图标、透明背景、抠图) or English.
---

# Codex image generation

Claude cannot generate images itself. This skill hands the image request to Codex CLI
(`codex exec` with its `$imagegen` tool), collects the resulting files, and, when a
transparent image is needed, removes a solid key-color background with a local script.

## Workflow

1. **Refine the prompt.** Turn the user's request (often Chinese) into one concrete
   English prompt: subject, style or medium, composition and framing, lighting, color
   palette, and what must not appear. Keep any text the image must contain in quotes.
   For an asset meant for a game or Unity, say so (e.g. "game UI icon, centered,
   readable at 64px").
2. **Choose options.**
   - Size: `square` (default), `landscape`, `portrait`, or `WxH`.
   - Count: `-c N` only when the user wants variations.
   - Reference images: `-r path` (repeatable) for edits, style matching, or keeping a
     character consistent.
   - Output: pass `-o` when the user names a place. Otherwise the default is
     `<git root>/assets/generated` inside a repo, else `~/Assets/generated`.
   - Name: `-n` with a short kebab-case description, e.g. `-n fire-spell-icon`.
3. **Transparent images.** When the user asks for transparency, a cut-out, a sticker,
   an icon or sprite for compositing, or a PNG "without background", add `-t`.
   The script instructs Codex to paint the subject on a flat key color, then a Python
   script keys it out. Pick the key color so it does not appear in the subject:
   - default `-k green` (#00FF00);
   - `-k magenta` when the subject is green, a plant, slime, or otherwise green-ish;
   - `-k blue` when the subject has both green and magenta/pink.
   Add `--trim` to crop to the subject (good for icons and sprites).
4. **Run it in the background.** One image takes roughly 30-120 seconds:
   ```bash
   ~/.claude/skills/codex-imagegen/scripts/imagegen.sh -p "<english prompt>" -n <name> [options]
   ```
   Use the Bash tool with `run_in_background: true` and keep talking with the user
   while it runs. stdout is one absolute path per image; progress goes to stderr.
5. **Check and show.** Open each output with the Read tool to see it. Confirm it
   matches the request, and for `-t` that the edges are clean and no key color is
   left. Tell the user the path(s). If the result misses, adjust the prompt and run
   again rather than describing what is wrong at length.

## Failure handling

| Exit code | Meaning | What to do |
|---|---|---|
| 3 | `codex` or `uv` missing, or Codex not logged in | Tell the user to run `codex login` (or `brew install codex` / `brew install uv`). Never try to log in for them. |
| 4 | Codex failed or timed out | Show the tail of the log it prints. Retry once with `--timeout 600` if it timed out. |
| 5 | Codex finished but produced no file | Usually a refused or misunderstood prompt. Rephrase, then retry once. |

If keying leaves a halo, rerun only the keyer on the kept source file
(`<name>-keyed-source.png`) with a different threshold:

```bash
uv run ~/.claude/skills/codex-imagegen/scripts/chroma_key.py SRC.png OUT.png --tolerance 80 --softness 100 --trim
```

Lower `--tolerance` if parts of the subject disappear. Raise it if background specks
remain. By default every key-colored pixel is removed, including background pockets
enclosed by the subject. If the subject really contains the key color (the prompt asks
Codex to avoid that), add `--keep-holes` so only border-connected background is removed.

## Notes

- Image generation uses the user's ChatGPT plan quota through Codex. Generate one
  image first. Make batches only when asked.
- Codex runs in a temporary directory with a `workspace-write` sandbox. It never
  touches the user's project files. Reference images are only attached as input.
- Do not put secrets, personal documents, or other people's private photos into
  prompts or reference images.
