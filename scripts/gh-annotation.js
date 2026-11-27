// Writes GitHub Actions `::error` workflow commands with their text escaped, so a test's name or message can't end the line or start another command.
'use strict';

// A command's message: GitHub reads %, CR and LF as escapes there.
function escapeData(s) {
  return String(s).replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
}

// A command's property value (title=...): also its separators, : and ,.
function escapeProperty(s) {
  return escapeData(s).replace(/:/g, '%3A').replace(/,/g, '%2C');
}

// One `::error title=...::message` line.
function errorLine(title, message) {
  return `::error title=${escapeProperty(title)}::${escapeData(message)}`;
}

// Plain log text on one line (a line break could start a workflow command).
function flat(s) {
  return String(s).replace(/[\r\n]+/g, ' ');
}

module.exports = { escapeData, escapeProperty, errorLine, flat };
