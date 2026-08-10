# Flyology HTTP website documentation guide

## Scope

Apply this technical writing style to hand-written pages in `guide/**` and
`architecture/**`. Apply the journal register below to `journal/**`. These
rules do not apply to the home page, reports, or generated API reference.

## Technical writing style

Use the useful parts of ASD-STE100 as a house style. Do not claim that the
documentation complies with ASD-STE100.

- Use the project vocabulary in the root `AGENTS.md`. Use one term for one
  concept. Do not add synonyms only for variety.
- Define an unfamiliar term before its first use. Keep Flyology HTTP
  identifiers, Ada terms, protocol terms, OS interfaces, and compiler terms
  exact.
- Put one main idea or instruction in each sentence. Use a list when three or
  more parallel facts would otherwise make a long sentence.
- Keep closely related cause, contrast, sequence, and consequence in the same
  paragraph. Do not split one connected explanation into abrupt statements
  only to meet a sentence-length target.
- Prefer sentences of 25 words or fewer. Prefer 20 words or fewer for an
  instruction. Treat these limits as review signals, not mechanical rules.
- Use active voice when the actor matters. Name the actor instead of using an
  unclear `it`, `this`, or `they`.
- Preserve modal meaning. Use `must` for a requirement, `can` for capability,
  and `may` for possibility. Do not replace a modal only for variety.
- Use the present tense for current behavior and the imperative for
  instructions. Put a condition before the action when it controls the action.
- Put a prerequisite or safety condition before its action. Natural forms such
  as "use X when Y" are acceptable when the condition does not gate safety,
  validity, or ownership.
- Use direct, sentence-case headings. State the subject or action. Do not use a
  clever title in place of information.
- Prefer concrete verbs to noun phrases. Avoid stacked modifiers,
  nominalizations, rhetorical questions, idioms, metaphors, personification,
  filler, and promotional language.
- Keep limits beside the capability that they qualify. Do not remove a
  condition, ownership rule, exception, or timing fact to make prose shorter.
- Use short paragraphs. Start a new paragraph when the subject or task changes.

The result must read like normal software documentation. Do not imitate an
aircraft maintenance manual, force a restricted dictionary, repeat nouns when
the reference is clear, or split connected reasoning into unnatural fragments.

Examples and walkthroughs can use a slightly more human cadence. Their setup
may explain why a realistic case matters, and their explanation may vary
sentence length to connect cause and effect. Use this allowance with restraint.
Commands, contracts, warnings, and limits still use the tighter style. Do not
add a fictional user, dramatic scenario, metaphor, or extra personality when
it does not improve understanding.

Review an example as a paragraph, not only as sentence-length scores. If three
or more short sentences have the same subject, combine or connect them when
this makes the sequence easier to follow. Retain a short sentence when it
states a warning, result, or important boundary.

Before finishing a documentation edit, check term consistency, sentence
length, HTML syntax, local links, and code examples. Sentence-length scripts
are triage tools, not acceptance gates. Review every flagged sentence for
meaning and cadence. Before normalizing related terms, confirm whether the
project uses them for different layers or mechanisms.

## API links

On each Guide, Architecture, or Journal page, link the first visible
explanatory mention of every project-owned public API entity to its generated
GNATdoc entry. This includes Flyology HTTP and the separate `flyology_iri`
crate. API entities include packages, generic packages, subprograms, types,
objects, exceptions, enumeration literals, and other documented declarations.

- Follow document reading order. The first mention can occur in a hero,
  callout, paragraph, list, table, or figure caption.
- Use `<a href="..."><code>Entity_Name</code></a>` for an identifier in prose.
- Link a package name to its GNATdoc unit page. Link a declaration to its exact
  entity anchor when that anchor exists.
- For an overloaded subprogram, link the declaration that matches the
  described operation. If prose refers to the overload family, link the
  package page.
- If an identifier first appears in a code block, code comment, or SVG text,
  link it in the nearest explanatory prose or caption. Do not put an HTML link
  inside a code block or SVG source label only to satisfy this rule.
- Do not guess a generated filename or anchor. Resolve it through generated
  GNATdoc output or its search index, then verify the target and fragment.
- Link only the first explanatory mention of an entity on a page. Repeat a
  link when the same spelling refers to a different entity or when a long page
  needs a deliberate navigation aid.
- Do not link Ada constructs, GNAT internals, protocol standards, OS
  interfaces, environment variables, commands, scripts, or external APIs to
  Flyology HTTP GNATdoc. Link external documentation only when authoritative
  and useful.
- When no generated entry exists for a project-owned public identifier, report
  it as a review finding. Do not link to an unrelated package.

## Journal register

Journal entries use the same exact vocabulary, concrete verbs, factual limits,
and aversion to promotional language. They can use a more personal voice.

- First person is acceptable when it identifies an observation, decision, or
  correction made by the author or project team.
- Use `we` for the project or team. Use `I` only when a named author records a
  direct observation or decision.
- Use past tense for dated work and observations. Use present tense for a
  current finding, implementation fact, or limit.
- Vary sentence length enough to keep a natural narrative. Do not apply the
  20-word and 25-word targets mechanically.
- Give the reason for an investigation and explain what changed in the team's
  understanding. Keep the evidence and its limits close to that account.
- A small amount of warmth or dry humor is acceptable. Do not use a conceit,
  extended metaphor, fictional scene, or dramatic claim to carry a technical
  explanation.
- Prefer a candid correction to defensive wording. Preserve the source
  revision, environment, method, result, and limits needed to evaluate a
  claim.

## Review roles

For a broad rewrite of three or more pages, use three separate read-only review
roles on the settled draft. Reviewers may work in parallel. They report
findings and do not edit the same checkout concurrently. Run a technical review
for any changed capability, limit, ownership, timing, or lifecycle claim.

Use one separate subagent for each role when multi-agent support is available.
Do not edit reviewed files while reviewers work. Give them a stable snapshot
when the checkout must continue changing.

Each finding identifies severity, exact location, relevant wording, violated
rule, and proposed correction. A technical finding also names the
implementation, script, contract, or invariant that supports it.

### Editorial reviewer

- Review headings, paragraph order, cadence, transitions, and cognitive load.
- Identify mechanical sentence splitting, repeated sentence openings, vague
  headings, and paragraphs that read like lists without list structure.
- Give examples enough connective prose to explain why one step follows
  another. Keep the tone restrained.
- Review the journal for a candid, personable voice without a persona or
  decorative story.

### Technical reviewer

- Compare the rewrite with earlier text, relevant implementation, runners, and
  root `AGENTS.md` invariants.
- Check that each page links the first explanatory mention of every
  project-owned public API entity to the correct generated GNATdoc entry,
  including entities from the separate `flyology_iri` crate.
- Check every condition, ownership rule, exception, timing fact, lifecycle
  boundary, concurrency limit, and experimental qualification.
- Check that every `must`, `can`, and `may` retains the intended requirement,
  capability, or possibility.
- Report facts that became weaker, broader, or ambiguous. Treat executable code
  and maintained scripts as stronger evidence than earlier prose.

### ASD-STE100-inspired controlled-language reviewer

- Apply this file's ASD-STE100-inspired rules without claiming compliance.
- Check one term per concept, active voice, clear actors and references,
  condition-before-action order, direct headings, and concrete verbs.
- Flag long or structurally complex sentences. Also flag excessive sentence
  splitting and repeated nouns that make prose unnatural.
- Distinguish instructions and warnings from explanatory examples. Apply the
  tighter sentence targets to the former, not mechanically to the latter.

The editing agent reconciles all three reviews. Technical fidelity wins when a
style suggestion would remove necessary meaning. Resolve technical findings
first, then editorial and controlled-language findings. Run a targeted
technical review on factual passages changed during reconciliation.

Review metadata, navigation labels, callouts, figure captions, SVG titles and
descriptions, code comments, and redirect text as well as body paragraphs. If
separate reviewers are unavailable, perform the three reviews in sequence and
label the notes. Do not collapse them into one generic prose pass.
