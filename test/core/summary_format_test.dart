import 'package:flutter_test/flutter_test.dart';
import 'package:splitlog_x/core/models/summary_format.dart';

void main() {
  test('standard format has no decoration', () {
    final rendered = renderSummaryEntry(
      format: standardSummaryFormat,
      title: '設計',
      time: '1.1h',
      memo: '仕様を確認\n実装を開始',
    );

    expect(rendered, '設計　1.1h\n仕様を確認\n実装を開始');
  });

  test('template format decorates every memo line', () {
    final rendered = renderSummaryEntry(
      format: templateSummaryFormat,
      title: '設計',
      time: '1.1h',
      memo: '仕様を確認\r\n実装を開始',
    );

    expect(rendered, '[設計]　(1.1h)\n   - 仕様を確認\n   - 実装を開始');
  });

  test('template rule targets the literal backslash-n string', () {
    final rendered = renderSummaryEntry(
      format: templateSummaryFormat,
      title: '設計',
      time: '1.1h',
      memo: r'仕様を確認\n実装を開始',
    );

    expect(rendered, '[設計]　(1.1h)\n   - 仕様を確認        - 実装を開始');
  });

  test('memo format is not applied to newlines inserted by a rule', () {
    const format = SummaryFormatDefinition(
      id: 'custom-newline',
      name: '改行テスト',
      titleTemplate: '{title}',
      timeTemplate: '{time}',
      memoTemplate: '   - {memo}',
      rules: [
        SummaryReplacementRule(
          id: 'rule-newline',
          match: '|',
          replacement: '\n        - ',
        ),
      ],
    );

    final rendered = renderSummaryEntry(
      format: format,
      title: '設計',
      time: '1.1h',
      memo: '仕様を確認|実装を開始',
    );

    expect(rendered, '設計　1.1h\n   - 仕様を確認\n        - 実装を開始');
  });

  test('trailing empty memo lines are not formatted', () {
    final rendered = renderSummaryEntry(
      format: templateSummaryFormat,
      title: '設計',
      time: '1.1h',
      memo: '仕様を確認\n\n',
    );

    expect(rendered, '[設計]　(1.1h)\n   - 仕様を確認');
  });

  test('custom replacement rules run from top to bottom', () {
    const format = SummaryFormatDefinition(
      id: 'custom-test',
      name: 'AI日報',
      titleTemplate: '#### {title}',
      timeTemplate: '{time}',
      memoTemplate: '{memo}',
      rules: [
        SummaryReplacementRule(
          id: 'rule-1',
          match: 'codex',
          replacement: '{match}(AI)',
        ),
        SummaryReplacementRule(
          id: 'rule-2',
          match: 'codex(AI)',
          replacement: 'AI',
        ),
      ],
    );

    final rendered = renderSummaryEntry(
      format: format,
      title: '実装',
      time: '45m',
      memo: 'codexで確認',
    );

    expect(rendered, '#### 実装　45m\nAIで確認');
  });

  test('memo row is omitted when memo is empty', () {
    final rendered = renderSummaryEntry(
      format: templateSummaryFormat,
      title: '確認',
      time: '0.2h',
      memo: '  ',
    );

    expect(rendered, '[確認]　(0.2h)');
  });
}
