# Codex code review, 2026-10-11

`codex-work exec`, gpt-6-astra, high reasoning. The work account ran out of credits after about 109k tokens, before Codex wrote its report, so this summary comes from its run log. Every finding below was reproduced and fixed in this repo.

## Confirmed and fixed

| # | Severity | Defect | Fix | Regression check |
|---|---|---|---|---|
| 1 | major | Anamorphic sources (DV widescreen, SAR 32:27 or 8:9) came out squeezed: the fit-to-frame scale used the stored width and ignored the pixel aspect ratio. | Unsqueeze to square pixels before fitting (`scale=trunc(iw*sar/2)*2:ih,setsar=1`). | Unit test; e2e measures a square at 1.18 wide-to-tall, was 1.00. |
| 2 | major | An audio track that starts after the video lost the offset. The raw AC-3 and H.264 both start at zero, so the sound played early. | `adelay` for late audio, `atrim` for early audio, from ffprobe `start_time`; applied to discrete joins too. | Unit tests; e2e checks a 1 s delay survives. |
| 3 | major | Cover art (`attached_pic`) was taken as the film: an audio file with artwork became a 64×64 encode, and a MOV with its cover stored first mapped the cover via `-map 0:v:0`. | Skip `attached_pic` streams in the probe; map the film's stream by index. | Unit test; e2e encodes a cover-first MP4 at 1920 wide. |
| 4 | minor | Clips of a few seconds failed with "empty or missing output": BDMV streams had to be ≥ 1 MiB. | Floor lowered to 32 KiB for stream files; ISOs keep 1 MiB, since an empty UDF image is larger than that. | e2e runs a 3 s clip in all three modes. |

## Found while verifying

- tsMuxeR writes its files 0640. Output is now set to 0644 (directories 0755), so it's readable from shared drives.
- ffmpeg prints "corrupt input packet" when reading any tsMuxeR M2TS. Not a defect: all 240 decoded frames of a test stream are bit-identical (framemd5) between the raw H.264, the M2TS and the BDMV stream. It comes from ffmpeg's continuity-counter check on tsMuxeR's packets.

## Not covered (credits ran out)

- Codex's sandbox couldn't mount disk images, so it didn't check ISO contents. `Scripts/e2e_test.sh` covers that locally.
- Packaging and licence review (`make_dmg.sh`, `release_signing.sh`, `prepare_runtime.py`) wasn't reached. Worth a rerun when credits are back.
