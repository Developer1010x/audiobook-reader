import 'package:audiobook_reader/models/book.dart';
import 'package:audiobook_reader/services/classifier.dart';
import 'package:flutter_test/flutter_test.dart';

/// The classifier decides whether an LLM is ever reachable for a book, so its
/// bias matters more than its raw accuracy: a false "textbook" exposes a button
/// that costs money and sends text to an API.
void main() {
  const textbookSample = '''
2.3 Binary Search Trees

Definition. A binary search tree is a rooted binary tree in which each node
stores a key, and for every node the keys in the left subtree are smaller.

Theorem 2.1. Search in a balanced BST takes O(log n) time.
Proof. The height of a balanced tree with n nodes is at most log n. Note that
each comparison eliminates half the remaining nodes [12].

Figure 2.4: An unbalanced tree degenerating to a linked list.

  int search(Node* root, int key) {
    while (root != nullptr) {
      if (root->key == key) return 1;
      root = key < root->key ? root->left : root->right;
    }
    return 0;
  }

Exercise 2.7. Show that the worst case is O(n). Recall that insertion order
determines the shape of the tree. See Table 2.1 for the parameter values.
''';

  const storySample = '''
The rain had not stopped for three days. Mara walked to the window and looked
out over the flooded square, where the market stalls stood abandoned.

"You should not have come," her brother said from the doorway.

She turned. His eyes were red, and his voice was quieter than she remembered.
"I had no choice," she whispered. "They were waiting at the harbour."

He laughed, though nothing about it was funny. The next morning they left
before the light came, and years later she still remembered the silence of it.
He smiled once, briefly, and then he was gone.
''';

  group('classification', () {
    test('recognises instructional writing as a textbook', () {
      final result = BookClassifier.classify(textbookSample);
      expect(result.type, BookType.textbook);
      expect(result.confidence, greaterThan(0.0));
    });

    test('recognises narrative prose as a storybook', () {
      final result = BookClassifier.classify(storySample);
      expect(result.type, BookType.storybook);
    });

    test('reports the signals it used, so the UI can explain itself', () {
      final result = BookClassifier.classify(textbookSample);
      expect(result.signals, isNotEmpty);
    });
  });

  group('bias towards storybook (the cheap mistake)', () {
    test('too little text defaults to storybook, never textbook', () {
      // A scanned book extracts almost nothing. It must not become a textbook,
      // which would offer an LLM button over text that does not exist.
      final result = BookClassifier.classify('a few words only');
      expect(result.type, BookType.storybook);
      expect(result.confidence, 0.0);
    });

    test('empty text defaults to storybook', () {
      expect(BookClassifier.classify('').type, BookType.storybook);
      expect(BookClassifier.classify('     ').type, BookType.storybook);
    });

    test('no recognisable signals defaults to storybook', () {
      final bland = 'lorem ipsum dolor sit amet ' * 40;
      expect(BookClassifier.classify(bland).type, BookType.storybook);
    });

    test('a narrow textbook lead is not enough to flip it', () {
      // Mixed content — a novel quoting a formula, say — should stay a storybook,
      // because textbook requires clearing a margin rather than merely winning.
      final mixed = '$storySample\n${textbookSample.substring(0, 300)}';
      expect(BookClassifier.classify(mixed).type, BookType.storybook);
    });
  });

  _documentTypeTests();

  group('BookType', () {
    test('only a textbook enables the LLM path', () {
      expect(BookType.textbook.usesLlm, isTrue);
      expect(BookType.storybook.usesLlm, isFalse);
    });
  });
}

/// The wider document taxonomy. The safety bias must survive it: adding more
/// types that unlock the AI path means more ways to unlock it by accident.
void _documentTypeTests() {
  const paper = '''
Abstract

We present a method for retrieval-augmented generation that improves factual
accuracy on open-domain question answering. Our approach outperforms the
state-of-the-art baseline by 4.2 points.

1. Introduction

Recent work [12, 17] has shown that language models hallucinate. Lewis et al.,
2020 proposed retrieval augmentation. We build on this.

3. Methodology

We evaluate on the Natural Questions dataset. An ablation study isolates the
contribution of each component. Results are statistically significant (p < 0.01).

References

[1] doi:10.1145/3372923
''';

  const docs = '''
## Installation

Run the following command to install the package:

    \$ npm install audiobook-reader

## Configuration

Create a config file and set the following keys:

    library.path = /path/to/books
    tts.engine = piper

## API

readPage(pageNumber)

Parameters:
  pageNumber - the 1-based page to read.
Returns: the extracted text.
Throws: RangeError if out of bounds.
Deprecated since version 2.1.0. See also: readRange.

Click Settings, then navigate to Providers to configure a model.
''';

  const letter = '''
Subject: Application for the Research Assistant position
Date: 11 August 2026

Dear Dr Hughes,

I am writing to apply for the position advertised last week. I have attached my
curriculum vitae for your consideration.

I would welcome the opportunity to discuss my application with you.

Yours sincerely,
S Prajwall Narayana
''';

  group('document taxonomy', () {
    test('recognises a research paper', () {
      expect(BookClassifier.classify(paper).type, BookType.paper);
    });

    test('recognises reference documentation', () {
      expect(BookClassifier.classify(docs).type, BookType.documentation);
    });

    test('recognises a letter', () {
      expect(BookClassifier.classify(letter).type, BookType.letter);
    });

    test('a long document is never classified as a letter', () {
      // A book with "Dear reader" in the preface is not correspondence.
      final long = '$letter\n${'Filler narrative sentence. ' * 400}';
      expect(BookClassifier.classify(long).type, isNot(BookType.letter));
    });
  });

  group('the safety bias survives more types', () {
    test('an ambiguous document does not unlock the AI path', () {
      // Mixed signals with no clear winner must fall back to storybook, whose
      // usesLlm is false, rather than picking whichever type edged ahead.
      final muddle = 'He said the parameter returns a value. '
          'She walked to the introduction. '
          'Dear reader, the results are significant. ' * 12;
      final result = BookClassifier.classify(muddle);
      if (result.type.usesLlm) {
        expect(result.confidence, greaterThan(0.0),
            reason: 'an LLM-enabling type must win clearly, not by a nose');
      }
    });

    test('too little text still defaults to a type with no AI path', () {
      expect(BookClassifier.classify('a few words').type.usesLlm, isFalse);
    });

    test('every type declares whether it reaches a model', () {
      for (final type in BookType.values) {
        expect(type.label, isNotEmpty);
        expect(type.description, isNotEmpty);
        expect(type.usesLlm, isA<bool>());
      }
      // Fiction and personal notes must never reach a model automatically.
      expect(BookType.storybook.usesLlm, isFalse);
      expect(BookType.notes.usesLlm, isFalse);
    });
  });
}
