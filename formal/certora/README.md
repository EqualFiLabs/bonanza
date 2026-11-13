# Reproduce the Certora proofs

The CVL specifications, Solidity proof harnesses, configurations and required
obligation inventory are version controlled. Execution results, compiler scenes,
logs and counterexamples are generated under ignored directories. No saved proof
result is needed to run this suite.

## Clone and prerequisites

```bash
git clone --recurse-submodules https://github.com/EqualFiLabs/bonanza.git
cd bonanza
git submodule update --init --recursive
```

Use the revision containing this package. Linux x86-64 is the documented reference
environment. Install Python 3.10, Git, Java 21 for execution, Z3 4.16.0, CVC5 1.4.2,
and Solidity compiler executables named `solc8.30` and `solc8.33` on `PATH`.
Lottery and Registry configurations use Solidity 0.8.30, Osaka, optimizer 200,
without via-IR. Router configurations use Solidity 0.8.33, Cancun, optimizer 200,
without via-IR. Submodule revisions are checked against `suite.json` before a run.

The runner uses the open-source CertoraProver release 8.20.2 at commit
`f5f77783430449791186f7812ebd53addf22cabd`. A hosted Certora account or API key is
not required. The source-matching Python CLI, helper executables and JAR are all
required; an unrelated packaged `certora-cli` installation is insufficient.

## Build the local prover

Follow the [pinned upstream build prerequisites](https://github.com/Certora/CertoraProver/blob/f5f77783430449791186f7812ebd53addf22cabd/README.md),
including Rust 1.90.0 and the native build tools. The reference build uses
Temurin JDK 19.0.2+7 and Gradle 7.6.4. Set `JAVA_HOME` to that build JDK and
`GRADLE_BIN` to the Gradle 7.6.4 executable. The upstream Gradle 7.2 wrapper
must not be run with the Java 21 execution runtime.

```bash
export CERTORA_LOCAL_ROOT="$PWD/.certora-tools"
mkdir -p "$CERTORA_LOCAL_ROOT/install"
git clone https://github.com/Certora/CertoraProver.git "$CERTORA_LOCAL_ROOT/source"
git -C "$CERTORA_LOCAL_ROOT/source" checkout --detach f5f77783430449791186f7812ebd53addf22cabd
git -C "$CERTORA_LOCAL_ROOT/source" submodule update --init --recursive
python3.10 -m venv "$CERTORA_LOCAL_ROOT/venv"
"$CERTORA_LOCAL_ROOT/venv/bin/python" -m pip install \
  -r "$CERTORA_LOCAL_ROOT/source/scripts/certora_cli_requirements.txt" \
  -r formal/certora/requirements-local.txt
export CERTORA="$CERTORA_LOCAL_ROOT/install"
export PATH="$JAVA_HOME/bin:$PATH"
export CARGO_BUILD_JOBS=4
(cd "$CERTORA_LOCAL_ROOT/source" && "$GRADLE_BIN" --no-daemon --max-workers=4 assemble)
```

Verify that `install` contains `certoraRun.py`, `emv.jar`, `tac_optimizer` and
the other upstream build outputs. Then select Java 21 for execution and put the
compiler aliases, CVC5 and the venv's `bin` directory on `PATH`:

```bash
export PATH="$CERTORA_LOCAL_ROOT/venv/bin:$PATH"
java -version
z3 --version
cvc5 --version
solc8.30 --version
solc8.33 --version
```

Z3 is provided by the pinned `z3-solver` Python dependency. Obtain CVC5 from its
[official 1.4.2 release](https://github.com/cvc5/cvc5/releases/tag/cvc5-1.4.2).
The reference `cvc5-Linux-x86_64-static.zip` SHA-256 is
`7eb18f8c814c36a46c5a7d003983e9cfbc4b0a9828d6dd596239291bd4cc61d8`.
Verify downloaded tool checksums. Source builds need not produce byte-identical
JAR archives on different machines. `CERTORA_JAR_SHA256` optionally requires an
operator-selected exact JAR digest; the runner always requires the pinned clean
prover source checkout.

## Run

Run on a provisioned verification system. The suites are resource intensive;
the default JVM heap ceiling is 16 GiB and each suite uses four concurrent rules.
Suites execute sequentially. Set `JAVA_TOOL_OPTIONS` explicitly to change JVM
resource limits.

```bash
"$CERTORA_LOCAL_ROOT/venv/bin/python" formal/scripts/run-certora.py --list
"$CERTORA_LOCAL_ROOT/venv/bin/python" formal/scripts/run-certora.py
# Or select individual named suites:
"$CERTORA_LOCAL_ROOT/venv/bin/python" formal/scripts/run-certora.py ownership-stepfinal callbacks-guard
```

The launcher selects an explicit local JAR, removes `CERTORAKEY` and blocks
hosted and split-rule submission paths. It does not invoke Halmos or make RPC
requests. Dependency downloads during setup are distinct from proof execution.
For long runs, use a terminal multiplexer or a recoverable background job.

Each invocation creates a fresh `.certora-results/<timestamp>/` directory.
Existing evidence is never overwritten. The process exits successfully only if
every selected suite has exit zero, the exact declared rule/method inventory,
successful constructor and induction cases, and all required nonvacuity and
nontriviality witnesses. Timeouts, errors, unknown statuses, missing cases and
vacuity fail the run. Expected sanity counterexamples have names ending in
`rule_not_vacuous` or `invariant_not_trivial_postcondition`; they are witnesses
that assumptions and assertions are reachable, not failures of the main rule.
`suite.json` declares those required checks; it contains no execution results.

Compiler scenes are generated in the ignored root `.certora_internal` directory.
All suites run from the repository root, including the configurations referencing
the pinned Registry and Router proof definitions. Those configurations provide
explicit dependency package mappings without modifying either submodule.

## Model scope

| Group | Definition and retained assumptions |
| --- | --- |
| History | Actual five-facet accounting/lifecycle induction and snapshot preservation; exact-transfer non-rebasing custody, passive summarized dependencies and approved fixed facets |
| Ownership | Actual range-history invariants, append identity and exact-source search-step induction over full production widths; termination follows from the uint32 capacity bound |
| Diamond | Actual singleton routing induction, reviewed composition to successful batches, initializer element induction and actual initialization rejection guards; approved initializer/facet code and EVM rollback |
| Callbacks | Arbitrary-input protected-call rejection and authority ledger frame; successful observed-delta checks assume truthful balances and ordinary approval semantics when composed with custody; failed-execution rules check atomic rollback |
| Ledger | Full-width allocation, settlement conservation/isolation and surplus absorption under the stated preconditions and stable custody summary |
| Registry | Existing pinned Registry state, acceptance-summary and runtime rules; these do not establish signature cryptography |
| Router | Existing pinned Router accounting and synchronization rules, linked to its formal token/Operator models and retained loop settings |

Source checkers reject drift between copied search/initializer elements and
production code. Mathematical composition of those elements into arbitrary
successful loops remains a reviewed source argument, distinct from a monolithic
unbounded-loop proof. Arbitrary new facets or delegatecall initializers are not
made safe by routing consistency or callback guards.

This command reproduces the Certora obligations only. Halmos signature
composition, primitive-model calibration, timelock scenarios, concrete fuzzing,
native-client vectors and fork lifecycles are separate validation methods.
Runtime/configuration/authority checks for an actual deployment remain separate
release conditions. Cryptographic security, compiler/EVM correctness, gas and
inclusion, sequencer behavior, governance and admitted-token semantics remain
explicit trust boundaries.
