import 'dart:convert';

// Vector fixture shared by desktop tests and the HarmonyOS device check.
List<int> pdfFixture({required int pageCount}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $pageCount /Kids [${List.generate(pageCount, (i) => '${3 + i * 2} 0 R').join(' ')}] >>',
  ];
  for (var i = 0; i < pageCount; i++) {
    final (width, height) = i == 2 ? (10000, 5000) : (100, 200);
    final color = ['1 0 0', '0 1 0', '0 0 1'][i % 3];
    final stream = '$color rg 0 0 $width $height re f\n';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
      '/Rotate ${i == 1 ? 90 : 0} /Resources << >> /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add('<< /Length ${stream.length} >>\nstream\n${stream}endstream');
  }
  final result = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(result.length);
    result.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = result.length;
  result.write('xref\n0 ${offsets.length}\n0000000000 65535 f \n');
  for (final offset in offsets.skip(1)) {
    result.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  result.write(
    'trailer\n<< /Size ${offsets.length} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return ascii.encode(result.toString());
}
