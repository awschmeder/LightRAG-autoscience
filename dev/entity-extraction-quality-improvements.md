# Entity Extraction Quality Improvements -- Analysis & Ideas

## Current Architecture Summary

The entity extraction pipeline flows through these stages:

```
Document -> chunking_by_token_size() -> extract_entities() -> _process_extraction_result() -> merge_nodes_and_edges()
```

### Chunking ([`chunking_by_token_size()`](lightrag/operate.py:99))
- Pure token-count windowing with configurable overlap (default 1200 tokens, 100 overlap)
- Optional `split_by_character` for pre-splitting on a delimiter before token windowing
- No semantic awareness -- splits mid-paragraph, mid-sentence, mid-entity

### Extraction ([`extract_entities()`](lightrag/operate.py:2813))
- Single LLM call per chunk with a ~200-line system prompt
- One optional "gleaning" pass (`entity_extract_max_gleaning`, default 1) that asks the LLM to find missed/malformed entities
- Gleaning merges by comparing description lengths -- longer description wins
- All chunks processed concurrently up to `llm_model_max_async`

### Parsing ([`_process_extraction_result()`](lightrag/operate.py:930))
- Line-based parsing of `entity<|#|>name<|#|>type<|#|>description` tuples
- Extensive error recovery for delimiter corruption
- [`sanitize_and_normalize_extracted_text()`](lightrag/utils.py:2094) applied to all fields
- Entity names truncated to 256 chars

### Merging ([`merge_nodes_and_edges()`](lightrag/operate.py:2443))
- Cross-chunk deduplication by exact entity name match
- Multiple descriptions for the same entity get LLM-summarized via [`_summarize_descriptions()`](lightrag/operate.py:297)
- No fuzzy matching, no synonym resolution at merge time

### System Prompt ([`entity_extraction_system_prompt`](lightrag/prompt.py:12))
- ~190 lines of detailed instructions covering:
  - Hard exclusions (document artifacts, meta-entities, bibliographic refs, etc.)
  - Naming conventions (Title Case, Scientific Casing, singularization, canonicalization)
  - Relationship extraction rules (directionality, decomposition, keyword normalization)
  - Final validation checklist
- Three few-shot examples (fiction, finance, sports)

---

## Identified Weaknesses

1. **Prompt length vs. instruction-following**: The system prompt is ~190 lines with dozens of rules. LLMs demonstrably degrade in instruction-following as prompt complexity increases. Many rules contradict each other in edge cases (e.g., "Title Case" vs. "Scientific Casing" vs. "Formula Protection").

2. **Single-pass extraction**: One LLM call must simultaneously extract entities, assign types, write descriptions, extract relationships, assign keywords, write relationship descriptions, apply all naming rules, and validate. This is a lot of cognitive load for a single generation.

3. **Gleaning is weak**: The gleaning prompt asks for "missed or incorrectly formatted" entities but provides no structured feedback about what was wrong. The merge logic only compares description length -- it cannot fix naming violations, type inconsistencies, or casing errors.

4. **No post-extraction validation**: The prompt says "Final Validation -- re-scan every entity" but this is aspirational -- the LLM has no mechanism to actually re-scan its own output before emitting it. There is no programmatic validation step.

5. **Chunking breaks context**: Token-based chunking splits mid-sentence and mid-paragraph. An entity mentioned at the boundary of two chunks may be extracted differently in each (different casing, different type, partial name).

6. **Deduplication is exact-match only**: `merge_nodes_and_edges` groups by exact entity name string. "Machine Learning" and "machine learning" and "ML" would create three separate nodes unless the LLM happens to canonicalize them identically in every chunk.

7. **Few-shot examples are domain-mismatched**: The three examples cover fiction, finance, and sports. For scientific papers (the primary use case based on the prompt's emphasis on scientific casing, chemical formulas, etc.), there are no domain-relevant examples.

---

## Improvement Ideas

### Category A: Multi-Pass Extraction (Decompose the Cognitive Load)

#### A1. Staged Extraction -- Entities First, Then Relationships
Split the single prompt into two sequential calls:
- **Pass 1**: Extract entities only (names, types, descriptions). Simpler prompt, shorter output.
- **Pass 2**: Given the extracted entity list + original text, extract relationships between them.

This reduces the generation complexity per call and lets the relationship pass reference a known entity vocabulary, reducing name mismatches between entity and relationship outputs.

#### A2. Iterative Salience-Based Extraction
As you suggested -- ask the LLM to extract only the top ~25% most salient entities per pass, repeating 3-4 times with previously extracted entities fed back. Benefits:
- Shorter generation per pass = fewer format errors
- Later passes can focus on subtler entities without being overwhelmed
- Natural deduplication feedback loop

Risk: 4x the LLM calls per chunk. Mitigate by making this optional and configurable.

#### A3. Extract-Then-Cleanup Pipeline
Your idea #4 -- use a loose "extract everything" prompt first, then follow with:
1. **Cleanup pass**: Review extracted entities against exclusion criteria, remove violations
2. **Normalization pass**: Apply casing rules, singularization, canonicalization
3. **Deduplication pass**: Merge synonyms and near-duplicates

This separates "recall" (find everything) from "precision" (filter and normalize), which aligns better with how LLMs perform.

### Category B: Post-Extraction Validation & Cleanup

#### B1. Programmatic Validation Layer
Add a Python-side validation step after parsing that checks:
- Entity names against hard exclusion regex patterns (Figure \d+, Table \d+, Section \d+, etc.)
- Entity name length (already done, but could be stricter)
- Entity type against a blacklist (thing, object, concept, entity, etc.)
- Casing consistency (detect mixed casing for the same entity across chunks)
- Relationship self-loops (src == tgt)
- Orphaned entities (no relationships)

This is cheap (no LLM calls) and catches the most common violations that the LLM ignores.

#### B2. LLM-Based Entity Cleanup Prompt
Your idea #2 -- a dedicated cleanup prompt that receives the extracted entity list and:
- Removes entities matching exclusion criteria
- Flags potential duplicates/synonyms
- Validates type assignments
- Checks description quality

This could operate on the aggregated entity list across all chunks for a document, catching cross-chunk inconsistencies.

#### B3. LLM-Based Normalization Prompt
Your idea #3 -- a dedicated prompt that:
- Applies Title Case / Scientific Casing rules
- Resolves acronyms to full forms (or vice versa)
- Singularizes plural entities
- Strips redundant category nouns
- Merges synonym groups into canonical names

This is particularly valuable because casing/normalization rules are where the current prompt most often fails -- they are mechanical rules that the LLM treats as suggestions.

### Category C: Chunking Improvements

#### C1. Semantic Chunking via LLM
Your latest idea -- use an LLM to identify logical split points:
- Feed the document to an LLM and ask it to output split-point indices at paragraph/section/topic boundaries
- Alternatively, use a smaller/cheaper model (or even an embedding-based approach) to detect topic shifts
- Respect section headers, paragraph breaks, and list boundaries

Benefits: Entities are never split across chunks; each chunk has coherent context for extraction.

Cost concern: An extra LLM call per document. Could use a cheaper model or a heuristic hybrid (split on headers/paragraphs first, then use LLM only for ambiguous boundaries).

#### C2. Sliding Window with Entity Carryover
Instead of independent chunks, use a sliding window where:
- Each chunk overlaps with the previous by a meaningful amount
- Entities extracted from the previous chunk are provided as context to the next chunk's extraction
- The LLM is told "these entities were already found in the preceding text -- reuse their exact names if they appear again"

This addresses cross-chunk consistency without requiring semantic chunking.

#### C3. Sentence-Boundary-Aware Chunking
A simpler alternative to full semantic chunking: use a sentence tokenizer (e.g., spaCy or even regex-based) to ensure chunks never split mid-sentence. This is nearly free computationally and eliminates the most egregious boundary artifacts.

### Category D: Prompt Engineering Improvements

#### D1. Prompt Decomposition -- Separate System Prompt Layers
Break the monolithic system prompt into modular sections that can be selectively included:
- **Core extraction rules** (always included, ~30 lines)
- **Naming conventions** (included as a reference card)
- **Domain-specific rules** (scientific, financial, etc. -- selected based on content)
- **Exclusion patterns** (could be a structured list rather than prose)

This reduces the effective prompt length for any given extraction.

#### D2. Domain-Matched Few-Shot Examples
Generate or curate few-shot examples that match the actual input domain:
- For scientific papers: examples with chemical formulas, gene names, methods, etc.
- For legal documents: examples with statutes, case names, regulatory bodies
- Could auto-select examples based on a lightweight domain classifier

The current examples (fiction, finance, sports) provide format guidance but not domain-relevant extraction patterns.

#### D3. Structured Output Format (JSON)
Replace the custom tuple-delimiter format with JSON output:
```json
{"entities": [{"name": "...", "type": "...", "description": "..."}],
 "relationships": [{"source": "...", "target": "...", "keywords": [...], "description": "..."}]}
```
Benefits:
- Most modern LLMs are trained extensively on JSON generation
- Eliminates the entire delimiter-corruption recovery code in `_process_extraction_result`
- Enables use of constrained decoding / JSON mode on supporting APIs
- Reduces parsing errors significantly

#### D4. Negative Examples in Few-Shot
Add examples showing what NOT to extract:
- "Figure 1" -> EXCLUDED (document artifact)
- "The Study" -> EXCLUDED (meta-entity)
- "p < 0.05" -> EXCLUDED (numeric value)

Negative examples are highly effective at teaching exclusion rules.

### Category E: Feedback & Self-Improvement Loops

#### E1. Extraction Quality Scoring
After extraction, run a lightweight evaluation:
- Count entities matching hard exclusion patterns (should be 0)
- Check casing consistency
- Check for orphaned entities
- Measure entity/relationship ratio (too few relationships suggests missed connections)
- Log a quality score per chunk

This enables monitoring extraction quality over time and across different LLM models.

#### E2. Prompt Optimization via A/B Testing
Your idea #5 -- implement a workflow that:
1. Samples random chunks from ingested documents
2. Runs multiple prompt variants against the same chunks
3. Scores results using the quality metrics from E1
4. Selects the best-performing prompt variant

This could be a CLI tool or a background job that periodically optimizes the extraction prompt.

#### E3. Human-in-the-Loop Feedback
Add an API endpoint or UI feature where users can:
- Flag incorrectly extracted entities
- Correct entity names/types
- Mark false relationships
- These corrections feed back into few-shot examples or fine-tuning data

### Category F: Cross-Chunk Entity Resolution

#### F1. Fuzzy Entity Deduplication at Merge Time
After all chunks are extracted, run a deduplication pass that:
- Groups entities by embedding similarity (using the existing embedding infrastructure)
- Applies string similarity (Levenshtein, Jaro-Winkler) as a secondary signal
- Presents candidate merge groups to an LLM for confirmation
- Merges confirmed duplicates into canonical forms

This catches "Machine Learning" / "ML" / "machine learning" that exact-match misses.

#### F2. Entity Registry with Canonical Names
Maintain a persistent registry of known entities and their canonical forms:
- When a new entity is extracted, check it against the registry
- If a close match exists, use the canonical form
- If no match, add it to the registry
- The registry grows over time and improves consistency across documents

---

## Recommended Priority Order

Based on impact-to-effort ratio:

| Priority | Idea | Impact | Effort |
|----------|------|--------|--------|
| 1 | B1. Programmatic Validation Layer | High | Low |
| 2 | D3. Structured Output (JSON) | High | Medium |
| 3 | C3. Sentence-Boundary Chunking | Medium | Low |
| 4 | A3. Extract-Then-Cleanup Pipeline | High | Medium |
| 5 | B3. LLM Normalization Prompt | High | Medium |
| 6 | D4. Negative Few-Shot Examples | Medium | Low |
| 7 | F1. Fuzzy Entity Deduplication | High | Medium |
| 8 | D2. Domain-Matched Examples | Medium | Medium |
| 9 | C1. Semantic Chunking via LLM | Medium | High |
| 10 | A1. Staged Extraction | Medium | High |
| 11 | E1. Quality Scoring | Medium | Medium |
| 12 | A2. Iterative Salience Extraction | Medium | High |
| 13 | E2. Prompt Optimization A/B | Medium | High |

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph Current Pipeline
        DOC[Document] --> CHUNK[Token-Based Chunking]
        CHUNK --> EXT[Single LLM Extraction Call]
        EXT --> GLEAN[Optional Gleaning Pass]
        GLEAN --> PARSE[Tuple Parser + Sanitization]
        PARSE --> MERGE[Exact-Match Merge + LLM Summary]
    end

    subgraph Proposed Enhancements
        DOC2[Document] --> SEMCHUNK[Semantic Chunking - C1/C3]
        SEMCHUNK --> EXT2[Loose Extraction Pass - A3]
        EXT2 --> CLEANUP[LLM Cleanup Pass - B2]
        CLEANUP --> NORM[LLM Normalization Pass - B3]
        NORM --> PROGVAL[Programmatic Validation - B1]
        PROGVAL --> FUZZY[Fuzzy Dedup + Entity Registry - F1/F2]
        FUZZY --> MERGE2[Merge + LLM Summary]
    end

    style Current Pipeline fill:#f9f0f0,stroke:#333
    style Proposed Enhancements fill:#f0f9f0,stroke:#333
```
