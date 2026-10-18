# Cache guard expression subset

`cache-expression.rb` is shared by `check-cache-mode.rb` (decoded YAML scalars) and
`check-cache-policy.sh` (a raw single-line `if:` mapping decoded by the Ruby CLI).
Neither caller trims the scalar. YAML quotes and comments are decoded before checking;
whitespace *inside* YAML quotes is retained.

The accepted template is exactly one whole-scalar `${{ expression }}` wrapper, with
no literal prefix or suffix. An unwrapped expression must contain no `${{` marker.
Mixed interpolation, padded wrappers and nested markers (even inside expression
strings) fail closed. For example, the following scalar is refused:

```yaml
if: github.ref == 'refs/heads/main' && steps.verified-source.outputs.protected-ancestor == 'true' && '${{ true }}'
```

The runner segments this into literal text and an interpolated expression before
parsing the condition. A guard-looking string segment cannot establish a guard.
The quoted scalar `if: " ${{ github.ref == 'refs/heads/main' }} "` is refused for
the same reason. YAML separation spaces outside a quoted scalar are not padding.
Rule N additionally refuses every restore condition written as a block scalar,
including `|-` and `>-`, and decoded CR/LF in any scalar style.

The deliberately bounded grammar supports:

- Single-quoted strings with doubled-quote escaping; lowercase `true`/`false`/`null` only;
  unsigned hexadecimal integers and optionally negative decimal numbers with fraction/exponent.
- Context roots `github`, `needs`, `vars`, `strategy`, `matrix`, `steps`, `inputs`, `job`,
  `runner`, `env` (case insensitive), followed by named properties or expression indexes.
  Direct postfix access on a literal (`true.ref`, `'x'[0]`) is refused. Grouped expressions,
  context accesses and function results may be indexed/dereferenced; they cannot be invoked.
- Grouping, unary `!`, comparisons `== != < <= > >=`, conjunction `&&`, disjunction `||`.
- Only these named functions (case insensitive), with these argument counts:
  `always/cancelled/failure/success`: 0; `contains/startsWith/endsWith`: 2;
  `fromJSON/toJSON`: 1; `join`: 1–2; `format/hashFiles`: 1–255.

Nonlowercase literal spellings (`TRUE`, `False`, `nUlL`) are names, not literals,
and fail as unknown context roots. Context and function lookup remains case insensitive.
Property names are separate: `inputs.TRUE`, `inputs.False` and `inputs.nUlL` are
accepted names; lowercase literal-spelled dot properties remain unsupported below.

Only exact unparenthesised top-level conjuncts establish required guards. A top-level
OR refuses the whole condition. Operators and parentheses inside strings are opaque;
function arguments and parenthesised subexpressions cannot manufacture a conjunct.
No expression is evaluated. Scalars are limited to 8192 bytes, token streams to 1024
and parser recursion to 64; the CLI also bounds its entire raw input to 8192 bytes.

This is a conservative policy subset, **not an Actions parser or conformance claim**.
Valid unsupported forms include wildcards (`needs[*].result`, `needs.*.result`),
lowercase literal-spelled dot properties (`inputs.true`, `inputs.false`, `inputs.null`;
use quoted indexes such as `inputs['true']`), `case()`,
NaN/Infinity and nested template markers in strings. YAML multiline forms are also
unsupported by the shell adapter. The shared parser does not establish per-job/step
context availability, property existence, function evaluation validity or the runner's
own size/depth constraints. Workflow syntax/lint and hosted policy admission remain
separate gates. Fixtures replay current deployed main guards, malicious string/OR
forms, template boundaries, literal case, function arities and invalid token contexts through both
adapters, plus the original Psych-key/block-scalar regression suite.

Semantics were checked against the official runner source at
`9abfe11d2abd9de09d3a8d933d7ed701ea0518a3`:
[template segmentation](https://github.com/actions/runner/blob/9abfe11d2abd9de09d3a8d933d7ed701ea0518a3/src/Sdk/DTObjectTemplating/ObjectTemplating/TemplateReader.cs),
[token contexts](https://github.com/actions/runner/blob/9abfe11d2abd9de09d3a8d933d7ed701ea0518a3/src/Sdk/DTExpressions2/Expressions2/Tokens/LexicalAnalyzer.cs),
[function arity checking](https://github.com/actions/runner/blob/9abfe11d2abd9de09d3a8d933d7ed701ea0518a3/src/Sdk/DTExpressions2/Expressions2/ExpressionParser.cs),
[builtin function declarations](https://github.com/actions/runner/blob/9abfe11d2abd9de09d3a8d933d7ed701ea0518a3/src/Sdk/DTExpressions2/Expressions2/ExpressionConstants.cs),
and [step contexts and condition functions](https://github.com/actions/runner/blob/9abfe11d2abd9de09d3a8d933d7ed701ea0518a3/src/Sdk/DTPipelines/Pipelines/ObjectTemplating/PipelineTemplateConverter.cs).
