const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const html = fs.readFileSync(path.join(__dirname, "..", "View-OneAgent.html"), "utf8");
const sandbox = { module: { exports: {} } };
vm.runInNewContext(html.match(/<script>([\s\S]*?)<\/script>/)[1], sandbox);
const { parseCsv, groupRows, resultEvidence } = sandbox.module.exports;
const headers = ["ConversationId", "ToolCallTime", "ToolName", "Status", "SqlQuery", "QueryResult", "UserMessage", "AgentResponse", "AgentId"];
const quote = value => '"' + value.replaceAll('"', '""') + '"';
const csv = rows => [headers, ...rows].map(row => row.map(quote).join(",")).join("\r\n");
const sample = ["conversation-1", "2026-01-02T10:00:00Z", "sample_tool", "Completed", "SELECT 1", '{"rows":[[1]],"columns":["count"]}', "Question", "Answer", "agent-1"];

test("PowerShell CSV: BOM, CRLF, embedded commas, quotes and multiline content", () => {
  const row = [...sample]; row[6] = 'Question, with "quotes"\r\nand another line';
  const parsed = parseCsv("\uFEFF" + csv([row]) + "\r\n");
  assert.equal(parsed.length, 1);
  assert.equal(parsed[0].UserMessage, row[6]);
  assert.equal(parsed[0].QueryResult, sample[5]);
  assert.equal(Object.keys(parsed[0]).length, headers.length);
});

test("header-only export is valid; malformed input fails explicitly", () => {
  assert.equal(parseCsv(csv([])).length, 0);
  for (const text of ["", "wrong,header", csv([sample]).slice(0, -1), csv([sample]) + "\nonly-one-field",
    csv([]) + '\n"closed"junk', csv([]) + '\nun"escaped', "a,a\n1,2"]) {
    assert.throws(() => parseCsv(text));
  }
});

test("grouping, chronology, failed-only filter and full-text search", () => {
  const later = [...sample]; later[1] = "2026-01-02T11:00:00Z"; later[3] = "Failed";
  later[4] = "SELECT failure";
  const otherAgent = [...sample]; otherAgent[8] = "agent-2";
  const rows = parseCsv(csv([later, sample, otherAgent]));
  const groups = groupRows(rows);
  assert.equal(groups.size, 2);
  assert.equal([...groups.values()][0][0].ToolCallTime, sample[1]);
  assert.equal([...groupRows(rows, "", true).values()][0].length, 1);
  assert.equal(groupRows(rows, "FAILURE").size, 1);
  assert.equal(groupRows(rows, "absent").size, 0);
  rows[0].ConversationId = ""; rows[1].ConversationId = "";
  assert.equal(groupRows(rows).size, 3);
});

test("tables only for complete supported shapes; raw/truncated evidence preserved", () => {
  const result = resultEvidence(sample[5]);
  assert.equal(result.table.rows[0][0], 1);
  assert.match(result.text, /\n/);
  assert.equal(resultEvidence('{"columns":["x"],"rows":[[1,2]]}').table, null);
  const truncated = '{"content": [{"text": "partial (truncated)';
  assert.equal(resultEvidence(truncated).text, truncated);
  assert.equal(resultEvidence(truncated).truncated, true);
  assert.equal(resultEvidence("ERROR: timed out").text, "ERROR: timed out");
  assert.equal(resultEvidence("").table, null);
  assert.equal(resultEvidence('{"columns":["x"],"rows":[["(truncated)"]]}').table, null);
});
