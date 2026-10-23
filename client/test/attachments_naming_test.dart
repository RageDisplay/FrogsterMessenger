import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/features/chat/attachments.dart';

void main() {
  // The name comes from whoever sent the file.
  group('a received file name', () {
    test('cannot climb out of the folder it is saved in', () {
      expect(AttachmentSaver.safeFileName(r'..\..\Windows\evil.txt'), 'evil.txt');
      expect(AttachmentSaver.safeFileName('../../.bashrc'), '.bashrc');
      expect(AttachmentSaver.safeFileName('..'), 'file');
      expect(AttachmentSaver.safeFileName(''), 'file');
    });

    test('means nothing to a shell or to Windows', () {
      expect(AttachmentSaver.safeFileName('a&calc.exe'), 'a_calc.exe');
      expect(AttachmentSaver.safeFileName('%APPDATA%.txt'), '_APPDATA_.txt');
      expect(AttachmentSaver.safeFileName('a<b>:c"|?*.txt'), 'a_b__c____.txt');
    });

    test('cannot hide a program behind trailing dots or spaces', () {
      final name = AttachmentSaver.safeFileName('invoice.pdf.exe. . ');
      expect(name, 'invoice.pdf.exe');
      expect(AttachmentSaver.isExecutable(name), isTrue);
    });
  });

  test('programs are recognised, documents are not', () {
    for (final name in ['setup.exe', 'run.BAT', 'x.ps1', 'link.lnk', 'a.msi', 'disk.iso', 'page.hta']) {
      expect(AttachmentSaver.isExecutable(name), isTrue, reason: name);
    }
    for (final name in ['photo.jpg', 'report.pdf', 'notes.txt', 'archive.zip', 'exe', 'song.mp3']) {
      expect(AttachmentSaver.isExecutable(name), isFalse, reason: name);
    }
  });

  test('types follow the extension, whatever its case', () {
    expect(AttachmentPicker.mimeTypeFor('IMG_1.JPG'), 'image/jpeg');
    expect(AttachmentPicker.mimeTypeFor('a.pdf'), 'application/pdf');
    expect(AttachmentPicker.mimeTypeFor('noext'), 'application/octet-stream');
  });
}
