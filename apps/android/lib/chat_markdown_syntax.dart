import 'package:markdown/markdown.dart' as md;

/// Numeric ranges use single tildes in model replies. Only explicit paired
/// double tildes mark deletion; code, escapes and links keep normal parsing.
final pocketMarkdownExtensions = md.ExtensionSet(
  md.ExtensionSet.gitHubFlavored.blockSyntaxes,
  [
    for (final syntax in md.ExtensionSet.gitHubFlavored.inlineSyntaxes)
      if (syntax is! md.StrikethroughSyntax) syntax,
    md.DelimiterSyntax(
      '~+',
      startCharacter: 0x7e,
      requiresDelimiterRun: true,
      allowIntraWord: true,
      tags: [md.DelimiterTag('del', 2)],
    ),
  ],
);
