import 'package:flutter_test/flutter_test.dart';
import 'package:portable_ai_flutter/services/llm_service.dart';

void main() {
  test('dedupeTrailingEcho removes mid-word sentence echo', () {
    const raw =
        "[chuckling] Oh, was I saying something already? [laugh] I was just "
        "telling you that I'm ready for whatever fun conversation or playful "
        "moment you want to share next! 😊 You tell me what sparks your "
        "interest, my dear. at sparks your interest, my dear.";
    final out = LlmService.dedupeTrailingEcho(raw);
    expect(out.contains('. at sparks'), isFalse, reason: 'OUT=$out');
    expect(out.endsWith('my dear.'), isTrue);
    expect(out.contains('what sparks your interest'), isTrue);
    expect(out.contains('[chuckling]'), isTrue);
    expect(out.contains('[laugh]'), isTrue);
  });

  test('stripControlTokens keeps emotions and drops echo + end tokens', () {
    const raw =
        'Hello there, friend. ello there, friend.<end|>';
    final out = LlmService.stripControlTokens(raw);
    expect(out, 'Hello there, friend.');
  });

  test('collapseExactRepeatedReply removes full duplicated reply', () {
    const once =
        '[wink] Well, since you are the best part of my day, I think we '
        'should just keep talking and laughing together for a little while '
        'longer! What sounds fun to your amazing imagination?';
    final doubled = '$once $once';
    final out = LlmService.collapseExactRepeatedReply(doubled);
    expect(out, once);
    expect(
      LlmService.stripControlTokens(doubled),
      once,
    );
  });
}
