//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Testing

@testable import ContainerCompose

struct InterpolationTests {
    private static let variables = ["A": "1", "B": "2", "EMPTY": "", "A_B": "ab"]

    private func interpolator(strict: Bool = true) -> Interpolator {
        var interpolator = Interpolator(lookup: { Self.variables[$0] })
        interpolator.strict = strict
        return interpolator
    }

    @Test(arguments: [
        ("plain text", "plain text"),
        ("$A", "1"),
        ("${A}", "1"),
        ("x${A}y", "x1y"),
        ("$A$B", "12"),
        ("${A_B}", "ab"),
        ("$A_B.c", "ab.c"),
        ("$$A", "$A"),
        ("$${A}", "${A}"),
        ("cost: $$5", "cost: $5"),
        ("${UNSET}", ""),
        ("${UNSET:-fallback}", "fallback"),
        ("${UNSET-fallback}", "fallback"),
        ("${EMPTY:-fallback}", "fallback"),
        ("${EMPTY-fallback}", ""),
        ("${A:-fallback}", "1"),
        ("${UNSET:-}", ""),
        ("${A:+other}", "other"),
        ("${A+other}", "other"),
        ("${UNSET:+other}", ""),
        ("${EMPTY:+other}", ""),
        ("${EMPTY+other}", "other"),
        ("${UNSET:-${A}}", "1"),
        ("${UNSET:-a${B}c}", "a2c"),
        ("${UNSET:-${ALSO_UNSET:-deep}}", "deep"),
        ("${A:?must be set}", "1"),
        ("${EMPTY?must be set}", ""),
        ("postgres://user:${UNSET:-secret}@db:5432/app", "postgres://user:secret@db:5432/app"),
        ("Host(`${A}.example.com`)", "Host(`1.example.com`)"),
    ])
    func substitutes(_ text: String, _ expected: String) throws {
        #expect(try interpolator().interpolate(text) == expected)
    }

    @Test(arguments: [
        ("${UNSET:?the database password}", "required variable UNSET is missing a value: the database password"),
        ("${EMPTY:?}", "required variable EMPTY is missing a value"),
        ("${UNSET?}", "required variable UNSET is missing a value"),
        ("ends with $", "write '$$' for a dollar sign"),
        ("price $5", "write '$$' for a dollar sign"),
        ("${A", "is never closed"),
        ("${}", "does not name a variable"),
        ("${1A}", "does not name a variable"),
        ("${A:x}", "is not a form compose knows"),
        ("${A/x/y}", "is not a form compose knows"),
    ])
    func refuses(_ text: String, _ reason: String) {
        #expect {
            try interpolator().interpolate(text)
        } throws: { error in
            "\(error)".contains(reason)
        }
    }

    @Test(arguments: [
        ("ends with $", "ends with $"),
        ("p$1word", "p$1word"),
        ("${A", "${A"),
        ("${}", "${}"),
        ("${A/x/y}", "${A/x/y}"),
        ("pa$$word", "pa$word"),
        ("$A and ${B}", "1 and 2"),
    ])
    func lenientKeepsWhatItCannotRead(_ text: String, _ expected: String) throws {
        #expect(try interpolator(strict: false).interpolate(text) == expected)
    }

    @Test
    func reportsOnlyVariablesUsedWithoutADefault() throws {
        var unset: [String] = []
        var interpolator = interpolator()
        interpolator.onUnset = { unset.append($0) }
        _ = try interpolator.interpolate("$MISSING ${ALSO_MISSING} ${HAS_DEFAULT:-x} ${ALTERNATIVE:+y} $A")
        #expect(unset == ["MISSING", "ALSO_MISSING"])
    }
}

struct ShellWordsTests {
    @Test(arguments: [
        ("a b c", ["a", "b", "c"]),
        ("  spaced   out\t", ["spaced", "out"]),
        ("server /data --console-address \":9001\"", ["server", "/data", "--console-address", ":9001"]),
        ("sh -c 'echo \"hi there\"'", ["sh", "-c", "echo \"hi there\""]),
        ("a\\ b", ["a b"]),
        ("\"a \\\"quoted\\\" b\"", ["a \"quoted\" b"]),
        ("\"keeps \\n as written\"", ["keeps \\n as written"]),
        ("''", [""]),
        ("a '' b", ["a", "", "b"]),
        ("\"$HOME\" '$HOME'", ["$HOME", "$HOME"]),
        ("--flag=\"two words\"", ["--flag=two words"]),
        ("", []),
        ("/bin/sh -c \" mc alias set minio http://minio:9000; exit 0; \"", ["/bin/sh", "-c", " mc alias set minio http://minio:9000; exit 0; "]),
    ])
    func splits(_ text: String, _ expected: [String]) throws {
        #expect(try ShellWords.split(text) == expected)
    }

    @Test(arguments: ["an 'open quote", "an \"open quote", "ends with \\"])
    func refuses(_ text: String) {
        #expect(throws: ShellWords.Failure.self) {
            try ShellWords.split(text)
        }
    }

    @Test(arguments: [
        ("plain", "plain"),
        ("KEY=value", "KEY=value"),
        ("/path/to:ro", "/path/to:ro"),
        ("two words", "'two words'"),
        ("it's", "'it'\\''s'"),
        ("", "''"),
        ("$HOME", "'$HOME'"),
        ("a;b", "'a;b'"),
    ])
    func quotes(_ word: String, _ expected: String) throws {
        #expect(ShellWords.quote(word) == expected)
        #expect(try ShellWords.split(ShellWords.quote(word)) == [word])
    }
}

struct DotEnvTests {
    @Test
    func readsEveryFormOfLine() throws {
        let text = """
            # a comment, then a blank line

            A=1
            export B=two words   # trailing comment
            C="quoted # not a comment"
            D='single $A'
            E="expanded ${A}"
            F=unquoted$A
            G=
            H
            I="multi
            line"
            J="tab\\tseparated and a \\"quote\\""
            K=p$1
              L = spaced
            M.N-O=dotted
            """
        let entries = try DotEnv.parse(text, file: ".env")
        let expected: [DotEnv.Entry] = [
            .init(key: "A", value: "1"),
            .init(key: "B", value: "two words"),
            .init(key: "C", value: "quoted # not a comment"),
            .init(key: "D", value: "single $A"),
            .init(key: "E", value: "expanded 1"),
            .init(key: "F", value: "unquoted1"),
            .init(key: "G", value: ""),
            .init(key: "H", value: nil),
            .init(key: "I", value: "multi\nline"),
            .init(key: "J", value: "tab\tseparated and a \"quote\""),
            .init(key: "K", value: "p$1"),
            .init(key: "L", value: "spaced"),
            .init(key: "M.N-O", value: "dotted"),
        ]
        #expect(entries == expected)
    }

    @Test
    func theEnvironmentWinsOverTheFile() throws {
        let entries = try DotEnv.parse("A=file\nB=${A}\nC=${ONLY_IN_ENV}", file: ".env") { name in
            ["A": "environment", "ONLY_IN_ENV": "yes"][name]
        }
        #expect(entries.map(\.value) == ["file", "environment", "yes"])
    }

    @Test
    func aWindowsFileReadsTheSame() throws {
        let entries = try DotEnv.parse("A=1\r\nB=2\r\n", file: ".env")
        #expect(entries == [.init(key: "A", value: "1"), .init(key: "B", value: "2")])
    }

    @Test(arguments: [
        ("not a pair", "is not a variable name"),
        ("=value", "is not a variable name"),
        ("A=\"never closed", "opens a quote that is never closed"),
        ("B='never closed\nC=1", "opens a quote that is never closed"),
    ])
    func refuses(_ text: String, _ reason: String) {
        #expect {
            try DotEnv.parse(text, file: ".env")
        } throws: { error in
            "\(error)".contains(reason) && "\(error)".contains(".env:1:1")
        }
    }
}

struct ComposeNodeTests {
    @Test
    func mergeKeysFillInWhatAMappingDoesNotSay() throws {
        let yaml = """
            base: &base
              a: 1
              b: 2
            one:
              <<: *base
              b: 3
            two:
              <<: [*base, {b: 9, c: 4}]
            three:
              b: 7
              <<: *base
            """
        let root = try ComposeNode.parse(yaml: yaml, file: "compose.yaml")
        func values(_ key: String) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (root[key]?.mapping ?? []).map { ($0.key, $0.value.scalar ?? "") })
        }
        #expect(values("one") == ["a": "1", "b": "3"])
        #expect(values("two") == ["a": "1", "b": "2", "c": "4"], "the first mapping to name a key keeps it")
        #expect(values("three") == ["a": "1", "b": "7"], "what the mapping says itself wins wherever the merge key sits")
    }

    @Test
    func aScalarIsTheTextTheFileHas() throws {
        let yaml = """
            port: 22:22
            flag: yes
            version: 1.10
            octal: 0755
            nothing:
            tilde: ~
            word: null
            quoted: "null"
            empty: ''
            block: |
              two
              lines
            """
        let root = try ComposeNode.parse(yaml: yaml + "\n", file: "compose.yaml")
        #expect(root["port"]?.scalar == "22:22")
        #expect(root["flag"]?.scalar == "yes")
        #expect(root["version"]?.scalar == "1.10")
        #expect(root["octal"]?.scalar == "0755")
        #expect(root["nothing"]?.isNull == true)
        #expect(root["tilde"]?.isNull == true)
        #expect(root["word"]?.isNull == true)
        #expect(root["quoted"]?.scalar == "null")
        #expect(root["empty"]?.scalar == "")
        #expect(root["block"]?.scalar == "two\nlines\n")
    }

    @Test
    func valuesKnowWhereTheyAre() throws {
        let yaml = """
            services:
              web:
                image: nginx
            """
        let root = try ComposeNode.parse(yaml: yaml, file: "dir/compose.yaml")
        let image = try #require(root["services"]?["web"]?["image"])
        #expect(image.location == SourceLocation(file: "dir/compose.yaml", line: 3, column: 12))
        #expect("\(image.location)" == "dir/compose.yaml:3:12")
    }

    @Test
    func anEmptyDocumentIsAnEmptyMapping() throws {
        #expect(try ComposeNode.parse(yaml: "", file: "compose.yaml").mapping?.isEmpty == true)
        #expect(try ComposeNode.parse(yaml: "# only a comment\n", file: "compose.yaml").mapping?.isEmpty == true)
    }

    @Test
    func invalidYAMLSaysWhere() {
        #expect {
            try ComposeNode.parse(yaml: "services:\n  web:\n    image: [unclosed\n", file: "compose.yaml")
        } throws: { error in
            let text = "\(error)"
            return text.contains("not valid YAML") && text.contains("compose.yaml:")
        }
    }

    @Test(arguments: ["ports: !reset []", "ports: !override\n      - 80:80", "image: !reset null"])
    func composeMergeTagsAreRefused(_ setting: String) {
        #expect {
            try ComposeNode.parse(yaml: "services:\n  web:\n    \(setting)\n", file: "compose.yaml")
        } throws: { error in
            "\(error)".contains("tag is not supported") && "\(error)".contains("compose.yaml:")
        }
    }

    @Test
    func aKeyGivenTwiceIsRefused() {
        #expect {
            try ComposeNode.parse(yaml: "services:\n  web:\n    image: a\n    image: b\n", file: "compose.yaml")
        } throws: { error in
            "\(error)".contains("image") && "\(error)".contains("more than once")
        }
    }
}
