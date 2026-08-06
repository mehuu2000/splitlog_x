const standardSummaryFormatId = 'standard';
const templateSummaryFormatId = 'template';

class SummaryReplacementRule {
  const SummaryReplacementRule({
    required this.id,
    required this.match,
    required this.replacement,
  });

  final String id;
  final String match;
  final String replacement;

  SummaryReplacementRule copyWith({
    String? id,
    String? match,
    String? replacement,
  }) {
    return SummaryReplacementRule(
      id: id ?? this.id,
      match: match ?? this.match,
      replacement: replacement ?? this.replacement,
    );
  }

  Map<String, Object?> toJson() {
    return {'id': id, 'match': match, 'replacement': replacement};
  }

  static SummaryReplacementRule fromJson(Map<String, Object?> json) {
    return SummaryReplacementRule(
      id: json['id'] as String? ?? '',
      match: json['match'] as String? ?? '',
      replacement: json['replacement'] as String? ?? '',
    );
  }
}

class SummaryFormatDefinition {
  const SummaryFormatDefinition({
    required this.id,
    required this.name,
    required this.titleTemplate,
    required this.timeTemplate,
    required this.memoTemplate,
    this.rules = const [],
  });

  final String id;
  final String name;
  final String titleTemplate;
  final String timeTemplate;
  final String memoTemplate;
  final List<SummaryReplacementRule> rules;

  bool get isBuiltIn =>
      id == standardSummaryFormatId || id == templateSummaryFormatId;

  SummaryFormatDefinition copyWith({
    String? id,
    String? name,
    String? titleTemplate,
    String? timeTemplate,
    String? memoTemplate,
    List<SummaryReplacementRule>? rules,
  }) {
    return SummaryFormatDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      titleTemplate: titleTemplate ?? this.titleTemplate,
      timeTemplate: timeTemplate ?? this.timeTemplate,
      memoTemplate: memoTemplate ?? this.memoTemplate,
      rules: rules ?? this.rules,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'titleTemplate': titleTemplate,
      'timeTemplate': timeTemplate,
      'memoTemplate': memoTemplate,
      'rules': rules.map((rule) => rule.toJson()).toList(),
    };
  }

  static SummaryFormatDefinition fromJson(Map<String, Object?> json) {
    final rules = switch (json['rules']) {
      final List<Object?> values =>
        values
            .whereType<Map<Object?, Object?>>()
            .map(
              (value) => SummaryReplacementRule.fromJson(
                value.map((key, value) => MapEntry(key.toString(), value)),
              ),
            )
            .toList(),
      _ => const <SummaryReplacementRule>[],
    };
    return SummaryFormatDefinition(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      titleTemplate: json['titleTemplate'] as String? ?? '{title}',
      timeTemplate: json['timeTemplate'] as String? ?? '{time}',
      memoTemplate: json['memoTemplate'] as String? ?? '{memo}',
      rules: rules,
    );
  }
}

const standardSummaryFormat = SummaryFormatDefinition(
  id: standardSummaryFormatId,
  name: '標準',
  titleTemplate: '{title}',
  timeTemplate: '{time}',
  memoTemplate: '{memo}',
);

const templateSummaryFormat = SummaryFormatDefinition(
  id: templateSummaryFormatId,
  name: 'テンプ',
  titleTemplate: '[ {title} ]',
  timeTemplate: '({time})',
  memoTemplate: '   ・{memo}',
  rules: [
    SummaryReplacementRule(
      id: 'template-newline',
      match: r'\n',
      replacement: '\n        - ',
    ),
  ],
);

const builtInSummaryFormats = [standardSummaryFormat, templateSummaryFormat];

SummaryFormatDefinition resolveSummaryFormat(
  String selectedId,
  List<SummaryFormatDefinition> customFormats,
) {
  for (final format in builtInSummaryFormats) {
    if (format.id == selectedId) {
      return format;
    }
  }
  for (final format in customFormats) {
    if (format.id == selectedId) {
      return format;
    }
  }
  return standardSummaryFormat;
}

String renderSummaryEntry({
  required SummaryFormatDefinition format,
  required String title,
  required String time,
  required String memo,
}) {
  final renderedTitle = format.titleTemplate.replaceAll('{title}', title);
  final renderedTime = format.timeTemplate.replaceAll('{time}', time);
  final heading = switch ((renderedTitle.isEmpty, renderedTime.isEmpty)) {
    (true, true) => '',
    (false, true) => renderedTitle,
    (true, false) => renderedTime,
    (false, false) => '$renderedTitle　$renderedTime',
  };

  if (memo.trim().isEmpty) {
    return heading;
  }

  final sourceLines = memo
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  while (sourceLines.isNotEmpty && sourceLines.last.trim().isEmpty) {
    sourceLines.removeLast();
  }

  final renderedMemo = sourceLines
      .map((sourceLine) {
        var transformedLine = sourceLine;
        for (final rule in format.rules) {
          if (rule.match.isEmpty) {
            continue;
          }
          final replacement = rule.replacement.replaceAll(
            '{match}',
            rule.match,
          );
          transformedLine = transformedLine.replaceAll(rule.match, replacement);
        }
        return format.memoTemplate.replaceAll('{memo}', transformedLine);
      })
      .join('\n');
  if (renderedMemo.isEmpty) {
    return heading;
  }
  if (heading.isEmpty) {
    return renderedMemo;
  }
  return '$heading\n$renderedMemo';
}
