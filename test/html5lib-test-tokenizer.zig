// Parts of this file were copied from
// https://github.com/watzon/zhtml, which is MIT (Expat) licensed.

// Copyright 2020 Chris Watson
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

const std = @import("std");
const testing = std.testing;
const Progress = std.Progress;

const pkg = @import("tokenizer");
const Token = pkg.Token;
const Tokenizer = pkg.Tokenizer;
const TokenizerState = pkg.TokenizerState;
const AttributeSet = pkg.AttributeSet;
const ParseError = pkg.ParseError;

test "content model flags" {
    try runTestFile("test/html5lib-tests/tokenizer/contentModelFlags.test");
}

test "domjs" {
    try runTestFile("test/html5lib-tests/tokenizer/domjs.test");
}

test "entities" {
    try runTestFile("test/html5lib-tests/tokenizer/entities.test");
}

test "escape flag" {
    try runTestFile("test/html5lib-tests/tokenizer/escapeFlag.test");
}

test "named entities" {
    try runTestFile("test/html5lib-tests/tokenizer/namedEntities.test");
}

test "numeric entities" {
    try runTestFile("test/html5lib-tests/tokenizer/numericEntities.test");
}

test "pending spec changes" {
    try runTestFile("test/html5lib-tests/tokenizer/pendingSpecChanges.test");
}

test "test 1" {
    try runTestFile("test/html5lib-tests/tokenizer/test1.test");
}

test "test 2" {
    try runTestFile("test/html5lib-tests/tokenizer/test2.test");
}

test "test 3" {
    try runTestFile("test/html5lib-tests/tokenizer/test3.test");
}

test "test 4" {
    try runTestFile("test/html5lib-tests/tokenizer/test4.test");
}

test "unicode chars" {
    try runTestFile("test/html5lib-tests/tokenizer/unicodeChars.test");
}

test "unicode chars problematic" {
    try runTestFile("test/html5lib-tests/tokenizer/unicodeCharsProblematic.test");
}

// Not supported at the moment.
// test "xml violation" {
//     try runTestFile("test/html5lib-tests/tokenizer/xmlViolation.test");
// }

fn runTestFile(file_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = &arena.allocator;

    var contents = try std.fs.cwd().readFileAlloc(allocator, file_path, std.math.maxInt(usize));
    defer allocator.free(contents);
    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();
    var tree = try parser.parse(contents);
    defer tree.deinit();

    var tests = tree.root.Object.get("tests").?.Array;
    var progress = Progress{};
    const prog_root = try progress.start("", tests.items.len);

    for (tests.items) |test_obj| {
        const description = test_obj.Object.get("description").?.String;
        if (std.mem.eql(u8, description, "Invalid Unicode character U+5FFFE")) {
            // The tokenizer reserves U+5FFFE for internal use.
            continue;
        }

        var states: [6]TokenizerState = undefined;
        var num_states: usize = 0;
        if (test_obj.Object.get("initialStates")) |initial_states_obj| {
            for (initial_states_obj.Array.items) |initial_state_val| {
                states[num_states] = parseInitialState(initial_state_val.String);
                num_states += 1;
            }
        } else {
            states[0] = .Data;
            num_states = 1;
        }

        var prog_task = prog_root.start(description, num_states);
        prog_task.activate();

        const double_escaped = if (test_obj.Object.get("doubleEscaped")) |de| de.Bool else false;
        const input = try getStringDecoded(test_obj.Object.get("input").?.String, allocator, double_escaped);
        defer allocator.free(input);
        const expected_tokens = try parseOutput(allocator, test_obj.Object.get("output").?.Array, double_escaped);
        defer expected_tokens.deinit();
        const expected_errors = blk: {
            if (test_obj.Object.get("errors")) |errors_obj| {
                break :blk try parseErrors(&arena.allocator, errors_obj.Array);
            } else {
                break :blk std.ArrayList(ErrorInfo).init(allocator);
            }
        };
        defer expected_errors.deinit();
        const last_start_tag = if (test_obj.Object.get("lastStartTag")) |lastStartTagObj| lastStartTagObj.String else null;

        for (states[0..num_states]) |state| {
            runTest(allocator, input, expected_tokens.items, expected_errors.items, state, last_start_tag) catch |err| {
                std.debug.print("Test \"{s}\" with initial state \"{s}\" failed\n", .{ description, @tagName(state) });
                return err;
            };
            prog_task.completeOne();
        }

        prog_task.end();
    }

    prog_root.end();
}

fn runTest(allocator: *std.mem.Allocator, input: []const u21, expected_tokens: []Token, expected_errors: []ErrorInfo, initial_state: TokenizerState, last_start_tag: ?[]const u8) !void {
    var tokenizer = Tokenizer{ .allocator = allocator, .input = input };
    defer tokenizer.deinit();
    tokenizer.changeTo(initial_state);
    if (last_start_tag) |name| {
        tokenizer.last_start_tag_name = try allocator.dupe(u8, name);
    }

    while (!tokenizer.reached_eof) {
        try tokenizer.run();
    }

    try std.testing.expect(tokenizer.tokens.items[tokenizer.tokens.items.len - 1] == .eof);
    std.testing.expectEqual(expected_tokens.len, tokenizer.tokens.items.len - 1) catch {
        std.debug.print("Unequal number of tokens\n Expected {}: {any}\n Actual {}: {any}\n", .{ expected_tokens.len, expected_tokens, tokenizer.tokens.items.len - 1, tokenizer.tokens.items[0 .. tokenizer.tokens.items.len - 1] });
        return error.UnequalNumberOfTokens;
    };
    for (expected_tokens) |token, i| {
        expectEqualTokens(token, tokenizer.tokens.items[i]) catch {
            std.debug.print("Mismatched tokens\n Expected: {any}\n Actual: {any}\n", .{ token, tokenizer.tokens.items[i] });
            return error.MismatchedTokens;
        };
    }

    std.testing.expectEqual(expected_errors.len, tokenizer.parse_errors.items.len) catch {
        std.debug.print("Unequal number of parse errors\n Expected {}: {any}\n Actual {}: {any}\n", .{ expected_errors.len, expected_errors, tokenizer.parse_errors.items.len, tokenizer.parse_errors.items });
        return error.UnequalNumberOfParseErrors;
    };
    for (expected_errors) |err, i| {
        testing.expectEqualSlices(u8, err.id, ErrorInfo.errorToSpecId(tokenizer.parse_errors.items[i])) catch {
            std.debug.print("Mismatched parse errors\n Expected: {s}\n Actual: {s}\n", .{ err.id, ErrorInfo.errorToSpecId(tokenizer.parse_errors.items[i]) });
            return error.MismatchedParseErrors;
        };
    }
}

fn parseOutput(allocator: *std.mem.Allocator, outputs: anytype, double_escaped: bool) !std.ArrayList(Token) {
    var tokens = try std.ArrayList(Token).initCapacity(allocator, outputs.items.len);
    for (outputs.items) |output_obj| {
        const output_array = output_obj.Array.items;
        const token_type_str = output_array[0].String;

        if (std.mem.eql(u8, token_type_str, "DOCTYPE")) {
            // ["DOCTYPE", name, public_id, system_id, correctness]
            try tokens.append(Token{
                .doctype = .{
                    .name = if (output_array[1] == .Null) null else try getString(output_array[1].String, allocator, double_escaped),
                    // public_id and system_id are either strings or null.
                    .public_identifier = if (output_array[2] == .Null) null else try getString(output_array[2].String, allocator, double_escaped),
                    .system_identifier = if (output_array[3] == .Null) null else try getString(output_array[3].String, allocator, double_escaped),
                    // correctness is either true or false; true corresponds to the force-quirks flag being false, and vice-versa.
                    .force_quirks = !output_array[4].Bool,
                },
            });
        } else if (std.mem.eql(u8, token_type_str, "StartTag")) {
            // ["StartTag", name, {attributes}*, true*]
            // ["StartTag", name, {attributes}]
            const attributes_obj = output_array[2].Object;
            var token = Token{
                .start_tag = .{
                    .name = try getString(output_array[1].String, allocator, double_escaped),
                    // When the self-closing flag is set, the StartTag array has true as its fourth entry.
                    // When the flag is not set, the array has only three entries for backwards compatibility.
                    .self_closing = if (output_array.len == 3) false else output_array[3].Bool,
                    .attributes = .{},
                },
            };
            var attributes_obj_it = attributes_obj.iterator();
            while (attributes_obj_it.next()) |attribute_entry| {
                try token.start_tag.attributes.put(allocator, try getString(attribute_entry.key_ptr.*, allocator, double_escaped), try getString(attribute_entry.value_ptr.String, allocator, double_escaped));
            }
            try tokens.append(token);
        } else if (std.mem.eql(u8, token_type_str, "EndTag")) {
            // ["EndTag", name]
            try tokens.append(Token{
                .end_tag = .{
                    .name = try getString(output_array[1].String, allocator, double_escaped),
                },
            });
        } else if (std.mem.eql(u8, token_type_str, "Comment")) {
            // ["Comment", data]
            try tokens.append(Token{
                .comment = .{ .data = try getString(output_array[1].String, allocator, double_escaped) },
            });
        } else if (std.mem.eql(u8, token_type_str, "Character")) {
            // ["Character", data]
            // All adjacent character tokens are coalesced into a single ["Character", data] token.
            const decoded = try getStringDecoded(output_array[1].String, allocator, double_escaped);
            defer allocator.free(decoded);
            for (decoded) |c| {
                try tokens.append(Token{ .character = .{ .data = c } });
            }
        }
    }
    return tokens;
}

pub fn parseErrors(allocator: *std.mem.Allocator, errors: anytype) !std.ArrayList(ErrorInfo) {
    var error_infos = try std.ArrayList(ErrorInfo).initCapacity(allocator, errors.items.len);
    for (errors.items) |error_obj| {
        const err_string = error_obj.Object.get("code").?.String;
        error_infos.appendAssumeCapacity(ErrorInfo{
            .id = err_string,
        });
    }
    return error_infos;
}

fn parseInitialState(str: []const u8) TokenizerState {
    const map = std.ComptimeStringMap(TokenizerState, .{
        .{ "Data state", TokenizerState.Data },
        .{ "PLAINTEXT state", TokenizerState.PLAINTEXT },
        .{ "RCDATA state", TokenizerState.RCDATA },
        .{ "RAWTEXT state", TokenizerState.RAWTEXT },
        .{ "Script data state", TokenizerState.ScriptData },
        .{ "CDATA section state", TokenizerState.CDATASection },
    });
    return map.get(str).?;
}

fn expectEqualAttributes(expected: AttributeSet, actual: AttributeSet) !void {
    try testing.expectEqual(expected.count(), actual.count());
    var expected_it = expected.iterator();
    while (expected_it.next()) |entry| {
        const expected_value = entry.value_ptr.*;
        const actual_value = actual.get(entry.key_ptr.*);
        try testing.expect(actual_value != null);
        try testing.expectEqualSlices(u8, expected_value, actual_value.?);
    }
}

fn expectEqualNullableSlices(comptime T: type, expected: ?[]const T, actual: ?[]const T) !void {
    if (expected) |e| {
        try testing.expect(actual != null);
        try testing.expectEqualSlices(T, e, actual.?);
    } else {
        try testing.expectEqual(expected, actual);
    }
}

fn expectEqualTokens(expected: Token, actual: Token) !void {
    const TokenTag = std.meta.Tag(Token);
    try testing.expect(@as(TokenTag, actual) == @as(TokenTag, expected));
    switch (expected) {
        .doctype => |d| {
            try expectEqualNullableSlices(u8, d.name, actual.doctype.name);
            try expectEqualNullableSlices(u8, d.public_identifier, actual.doctype.public_identifier);
            try expectEqualNullableSlices(u8, d.system_identifier, actual.doctype.system_identifier);
            try testing.expectEqual(d.force_quirks, actual.doctype.force_quirks);
        },
        .start_tag => {
            try expectEqualNullableSlices(u8, expected.start_tag.name, actual.start_tag.name);
            try testing.expectEqual(expected.start_tag.self_closing, actual.start_tag.self_closing);
            try expectEqualAttributes(expected.start_tag.attributes, actual.start_tag.attributes);
        },
        .end_tag => {
            try expectEqualNullableSlices(u8, expected.end_tag.name, actual.end_tag.name);
            // Don't compare selfClosing or attributes. From the spec:
            // An end tag that has a / right before the closing > is treated as a regular end tag.
            // Attributes in end tags are completely ignored and do not make their way into the DOM.
        },
        .comment => {
            try expectEqualNullableSlices(u8, expected.comment.data, actual.comment.data);
        },
        .character => {
            try testing.expectEqual(expected.character.data, actual.character.data);
        },
        .eof => unreachable,
    }
}

const ErrorInfo = struct {
    id: []const u8,
    //line: usize,
    //column: usize,

    pub fn errorToSpecId(err: ParseError) []const u8 {
        // there might be a cleverer way to do this but oh well
        return switch (err) {
            ParseError.AbruptClosingOfEmptyComment => "abrupt-closing-of-empty-comment",
            ParseError.AbruptDOCTYPEPublicIdentifier => "abrupt-doctype-public-identifier",
            ParseError.AbruptDOCTYPESystemIdentifier => "abrupt-doctype-system-identifier",
            ParseError.AbsenceOfDigitsInNumericCharacterReference => "absence-of-digits-in-numeric-character-reference",
            ParseError.CDATAInHtmlContent => "cdata-in-html-content",
            ParseError.CharacterReferenceOutsideUnicodeRange => "character-reference-outside-unicode-range",
            ParseError.ControlCharacterInInputStream => "control-character-in-input-stream",
            ParseError.ControlCharacterReference => "control-character-reference",
            ParseError.EndTagWithAttributes => "end-tag-with-attributes",
            ParseError.DuplicateAttribute => "duplicate-attribute",
            ParseError.EndTagWithTrailingSolidus => "end-tag-with-trailing-solidus",
            ParseError.EOFBeforeTagName => "eof-before-tag-name",
            ParseError.EOFInCDATA => "eof-in-cdata",
            ParseError.EOFInComment => "eof-in-comment",
            ParseError.EOFInDOCTYPE => "eof-in-doctype",
            ParseError.EOFInScriptHtmlCommentLikeText => "eof-in-script-html-comment-like-text",
            ParseError.EOFInTag => "eof-in-tag",
            ParseError.IncorrectlyClosedComment => "incorrectly-closed-comment",
            ParseError.IncorrectlyOpenedComment => "incorrectly-opened-comment",
            ParseError.InvalidCharacterSequenceAfterDOCTYPEName => "invalid-character-sequence-after-doctype-name",
            ParseError.InvalidFirstCharacterOfTagName => "invalid-first-character-of-tag-name",
            ParseError.MissingAttributeValue => "missing-attribute-value",
            ParseError.MissingDOCTYPEName => "missing-doctype-name",
            ParseError.MissingDOCTYPEPublicIdentifier => "missing-doctype-public-identifier",
            ParseError.MissingDOCTYPESystemIdentifier => "missing-doctype-system-identifier",
            ParseError.MissingEndTagName => "missing-end-tag-name",
            ParseError.MissingQuoteBeforeDOCTYPEPublicIdentifier => "missing-quote-before-doctype-public-identifier",
            ParseError.MissingQuoteBeforeDOCTYPESystemIdentifier => "missing-quote-before-doctype-system-identifier",
            ParseError.MissingSemicolonAfterCharacterReference => "missing-semicolon-after-character-reference",
            ParseError.MissingWhitespaceAfterDOCTYPEPublicKeyword => "missing-whitespace-after-doctype-public-keyword",
            ParseError.MissingWhitespaceAfterDOCTYPESystemKeyword => "missing-whitespace-after-doctype-system-keyword",
            ParseError.MissingWhitespaceBeforeDOCTYPEName => "missing-whitespace-before-doctype-name",
            ParseError.MissingWhitespaceBetweenAttributes => "missing-whitespace-between-attributes",
            ParseError.MissingWhitespaceBetweenDOCTYPEPublicAndSystemIdentifiers => "missing-whitespace-between-doctype-public-and-system-identifiers",
            ParseError.NestedComment => "nested-comment",
            ParseError.NoncharacterCharacterReference => "noncharacter-character-reference",
            ParseError.NoncharacterInInputStream => "noncharacter-in-input-stream",
            ParseError.NonVoidHtmlElementStartTagWithTrailingSolidus => "non-void-html-element-start-tag-with-trailing-solidus",
            ParseError.NullCharacterReference => "null-character-reference",
            ParseError.SurrogateCharacterReference => "surrogate-character-reference",
            ParseError.SurrogateInInputStream => "surrogate-in-input-stream",
            ParseError.UnexpectedCharacterAfterDOCTYPESystemIdentifier => "unexpected-character-after-doctype-system-identifier",
            ParseError.UnexpectedCharacterInAttributeName => "unexpected-character-in-attribute-name",
            ParseError.UnexpectedCharacterInUnquotedAttributeValue => "unexpected-character-in-unquoted-attribute-value",
            ParseError.UnexpectedEqualsSignBeforeAttributeName => "unexpected-equals-sign-before-attribute-name",
            ParseError.UnexpectedNullCharacter => "unexpected-null-character",
            ParseError.UnexpectedQuestionMarkInsteadOfTagName => "unexpected-question-mark-instead-of-tag-name",
            ParseError.UnexpectedSolidusInTag => "unexpected-solidus-in-tag",
            ParseError.UnknownNamedCharacterReference => "unknown-named-character-reference",
        };
    }

    pub fn format(value: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{s}", .{value.id});
    }
};

fn getString(string: []const u8, allocator: *std.mem.Allocator, double_escaped: bool) ![]u8 {
    if (!double_escaped) {
        return allocator.dupe(u8, string);
    } else {
        return doubleEscape(allocator, string);
    }
}

fn getStringDecoded(string: []const u8, allocator: *std.mem.Allocator, double_escaped: bool) ![]u21 {
    if (!double_escaped) {
        var it = (try std.unicode.Utf8View.init(string)).iterator();
        var list = std.ArrayList(u21).init(allocator);
        errdefer list.deinit();
        while (it.nextCodepoint()) |cp| {
            try list.append(cp);
        }
        return list.toOwnedSlice();
    } else {
        return decodeDoubleEscape(allocator, string);
    }
}

fn doubleEscape(allocator: *std.mem.Allocator, string: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    var state: enum { Data, Backslash, Unicode } = .Data;

    var pos: usize = 0;
    while (pos < string.len) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(string[pos]) catch unreachable;
        switch (state) {
            .Data => {
                defer pos += codepoint_len;
                switch (string[pos]) {
                    '\\' => state = .Backslash,
                    else => |c| try result.append(c),
                }
            },
            .Backslash => {
                defer pos += codepoint_len;
                switch (string[pos]) {
                    'u' => state = .Unicode,
                    else => |c| {
                        try result.append('\\');
                        try result.append(c);
                        state = .Data;
                    },
                }
            },
            .Unicode => {
                defer pos += 4;
                const codepoint = std.fmt.parseUnsigned(u21, string[pos .. pos + 4], 16) catch unreachable;
                var code_units: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &code_units) catch unreachable;
                try result.appendSlice(code_units[0..len]);
                state = .Data;
            },
        }
    }

    return result.toOwnedSlice();
}

fn decodeDoubleEscape(allocator: *std.mem.Allocator, string: []const u8) ![]u21 {
    var result = std.ArrayList(u21).init(allocator);
    errdefer result.deinit();
    var state: enum { Data, Backslash, Unicode } = .Data;

    var pos: usize = 0;
    while (pos < string.len) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(string[pos]) catch unreachable;
        switch (state) {
            .Data => {
                defer pos += codepoint_len;
                switch (string[pos]) {
                    '\\' => state = .Backslash,
                    else => |c| try result.append(c),
                }
            },
            .Backslash => {
                defer pos += codepoint_len;
                switch (string[pos]) {
                    'u' => state = .Unicode,
                    else => |c| {
                        try result.append('\\');
                        try result.append(c);
                        state = .Data;
                    },
                }
            },
            .Unicode => {
                defer pos += 4;
                const codepoint = std.fmt.parseUnsigned(u21, string[pos .. pos + 4], 16) catch unreachable;
                try result.append(codepoint);
                state = .Data;
            },
        }
    }

    return result.toOwnedSlice();
}
