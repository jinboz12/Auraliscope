"""Prints the Swift sources that scripts/test.sh compiles into its one AnalysisCore module, without its test files.

Probes that need the analysis (not the tests) compile this list, so they stay in step with test.sh's `sources` array.
"""
import pathlib

text = pathlib.Path("scripts/test.sh").read_text()
start = text.index("sources=(") + len("sources=(")
end = text.index(")", text.index('CaptureCallback.o"', start))
for token in text[start:end].split():
    if token.endswith(".swift") and not token.startswith("Tests/"):
        print(token)
