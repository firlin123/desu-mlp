# desu-mlp

Automated archival pipeline for the 4chan **/mlp/** board.

This repository powers the automated daily scraping, consolidation, and uploading
for the [/mlp/ Archive on the Internet Archive](https://archive.org/details/desu-mlp).
It contains the GitHub Actions workflows and scripts necessary to continuously
fetch new posts, manage releases, and reconstruct the full board history.

## Reconstructing the Archive

You don’t need to clone this repository to get the full dataset.

The standalone `reconstruct.sh` script automatically pulls down the latest
manifest, downloads all needed pieces (yearly archives from the Internet Archive,
plus monthly and daily chunks from GitHub Releases), and stitches them together
into a single NDJSON file.

```bash
curl -O https://raw.githubusercontent.com/firlin123/desu-mlp/main/reconstruct.sh
chmod +x reconstruct.sh
./reconstruct.sh
```

This will result in a ~65 GB NDJSON file (as of the last update).  
Have at least double that (130 GB of free disk space) available for temporary files during
reconstruction.

## How It Works

The archival process runs in three stages:

1. **Daily Scrapes:**  
   New posts are fetched every day from `desuarchive.org`
   (with fallbacks to `arch.b4k.dev` and `archived.moe` if needed).  
   Each batch of new posts is compressed and uploaded as a **Daily Release**.

2. **Monthly Consolidation:**  
   On the **17th of every month**, all daily releases from the previous period are
   merged into a single **Monthly Release**.  
   Once the monthly file is uploaded, the older daily releases are deleted to
   reduce repository size.

3. **Yearly Consolidation & Internet Archive Upload:**  
   After **February 17th** each year (the anniversary of /mlp/’s creation), and
   following a short **two-day delay**, all monthly releases from the past year are
   combined into a **Yearly Release**.  
   This yearly archive is then uploaded to the Internet Archive, and the monthly
   releases it was built from are removed.

## Data Format & Schema

The archive data is stored in **NDJSON (Newline Delimited JSON)** format and
compressed using **XZ**. Each line represents a single post object structured to
match the desuarchive (FoolFuuka) API response.

### Data Sources

Posts are aggregated from multiple archival sources for maximum completeness:

- `desuarchive.org`
- `archive.heinessen.com`
- `arch.b4k.dev`
- `archived.moe`
- `yuki.la`
- `4archive.org`

Data from older or non-FoolFuuka archives (like Heinessen, Yuki.la, or 4archive.org) is normalized to match the desuarchive schema for consistency.

Fallback posts retrieved from non-desu sources use the otherwise-unused `extra_data` field to record their origin. For example, a post is from arch.b4k.dev it will have:
```json
"extra_data": [{"source": "arch.b4k.dev"}]
```

### Missing Posts

Posts that cannot be found in any known source are preserved as placeholders to
maintain numbering continuity:

```json
{"num": "123456", "exception": "Post: not found", "timestamp": 1646187447}
```

The `timestamp` records when the "post not found" response was received.
