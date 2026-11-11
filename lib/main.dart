import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Store.load();
  runApp(const PaperReaderApp());
}

// ---------------------------------------------------------------- data

class Book {
  Book({
    required this.id,
    required this.title,
    required this.path,
    this.lastPage = 0,
    this.pages = 0,
  });

  final String id;
  final String title;
  final String path;
  int lastPage;
  int pages;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'lastPage': lastPage,
        'pages': pages,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        id: j['id'] as String,
        title: j['title'] as String,
        path: j['path'] as String,
        lastPage: (j['lastPage'] as int?) ?? 0,
        pages: (j['pages'] as int?) ?? 0,
      );
}

class Store {
  static late SharedPreferences prefs;
  static List<Book> books = [];
  static int streak = 0;
  static String lastDay = '';
  static bool night = false;

  static Future<void> load() async {
    prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('books');
    if (raw != null) {
      books = (jsonDecode(raw) as List)
          .map((e) => Book.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    streak = prefs.getInt('streak') ?? 0;
    lastDay = prefs.getString('lastDay') ?? '';
    night = prefs.getBool('night') ?? false;
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    if (lastDay != _fmt(now) && lastDay != _fmt(yesterday)) streak = 0;
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static Future<void> save() async {
    await prefs.setString(
        'books', jsonEncode(books.map((b) => b.toJson()).toList()));
    await prefs.setInt('streak', streak);
    await prefs.setString('lastDay', lastDay);
    await prefs.setBool('night', night);
  }

  /// Counts today as a reading day (once per day).
  static Future<void> markReadToday() async {
    final now = DateTime.now();
    final today = _fmt(now);
    if (lastDay == today) return;
    final yesterday = _fmt(now.subtract(const Duration(days: 1)));
    streak = lastDay == yesterday ? streak + 1 : 1;
    lastDay = today;
    await save();
  }
}

// ---------------------------------------------------------------- app

class PaperReaderApp extends StatelessWidget {
  const PaperReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Paper Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF8B5E3C),
        textTheme: ThemeData.light().textTheme.apply(fontSizeFactor: 1.2),
      ),
      home: const LibraryScreen(),
    );
  }
}

// ---------------------------------------------------------------- bookcase

Color _shade(Color c, double a) =>
    a >= 0 ? Color.lerp(c, Colors.white, a)! : Color.lerp(c, Colors.black, -a)!;

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _coverColors = [
    Color(0xFF7B2D26),
    Color(0xFF1F4E5F),
    Color(0xFF3B5B3A),
    Color(0xFF5B3A6B),
    Color(0xFF8A5A1E),
    Color(0xFF2B3A67),
    Color(0xFF6B1E3A),
    Color(0xFF2F5D50),
  ];
  static const double _shelfHeight = 250;
  static const double _boardHeight = 40;

  Future<void> _addPdf() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    final file = res?.files.single;
    if (file == null || file.path == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final dest = '${dir.path}/$id.pdf';
    await File(file.path!).copy(dest);
    final title = file.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
    Store.books.add(Book(id: id, title: title, path: dest));
    await Store.save();
    if (mounted) setState(() {});
  }

  Future<void> _confirmRemove(Book b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove "${b.title}"?', style: const TextStyle(fontSize: 22)),
        content: const Text('This removes it from your bookcase.',
            style: TextStyle(fontSize: 18)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancel', style: TextStyle(fontSize: 18))),
          TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Remove', style: TextStyle(fontSize: 18))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(b.path).delete();
    } catch (_) {}
    Store.books.remove(b);
    await Store.save();
    if (mounted) setState(() {});
  }

  Future<void> _open(Book b) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => ReaderScreen(book: b)));
    if (mounted) setState(() {});
  }

  double _spineWidth(Book b) {
    if (b.pages > 0) return (40 + b.pages * 0.12).clamp(46.0, 78.0).toDouble();
    return 48.0 + (b.id.hashCode.abs() % 5) * 5.0;
  }

  double _spineHeight(Book b) => 150.0 + (b.id.hashCode.abs() % 5) * 10.0;

  Widget _spine(Book b) {
    final color = _coverColors[b.id.hashCode.abs() % _coverColors.length];
    final w = _spineWidth(b);
    final h = _spineHeight(b);
    final gold = const Color(0xFFE2C275);
    return GestureDetector(
      onTap: () => _open(b),
      onLongPress: () => _confirmRemove(b),
      child: Container(
        width: w,
        height: h,
        margin: const EdgeInsets.only(right: 3),
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(3),
            topRight: Radius.circular(3),
          ),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              _shade(color, -0.55),
              color,
              _shade(color, 0.18),
              color,
              _shade(color, -0.6),
            ],
            stops: const [0.0, 0.2, 0.42, 0.72, 1.0],
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black87, blurRadius: 6, offset: Offset(3, 2)),
          ],
        ),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 6,
              child: Container(color: _shade(color, -0.35)),
            ),
            Positioned(left: 0, right: 0, top: 14, height: 3, child: Container(color: gold)),
            Positioned(left: 0, right: 0, top: 20, height: 1.5, child: Container(color: gold)),
            Positioned(left: 0, right: 0, bottom: 14, height: 3, child: Container(color: gold)),
            Positioned(left: 0, right: 0, bottom: 20, height: 1.5, child: Container(color: gold)),
            Positioned.fill(
              top: 26,
              bottom: 26,
              child: Center(
                child: RotatedBox(
                  quarterTurns: 1,
                  child: Text(
                    b.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<List<Book>> _rows(double avail) {
    final rows = <List<Book>>[];
    var cur = <Book>[];
    var used = 0.0;
    for (final b in Store.books) {
      final w = _spineWidth(b) + 3;
      if (used + w > avail && cur.isNotEmpty) {
        rows.add(cur);
        cur = [];
        used = 0;
      }
      cur.add(b);
      used += w;
    }
    if (cur.isNotEmpty) rows.add(cur);
    while (rows.length < 3) {
      rows.add([]);
    }
    return rows;
  }

  Widget _shelf(List<Book> books, {String? hint}) {
    return SizedBox(
      height: _shelfHeight,
      child: Stack(
        children: [
          // back wall of the bookcase, darker at the top (shadow of shelf above)
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF120A05), Color(0xFF2E1D10), Color(0xFF3A2515)],
                ),
              ),
            ),
          ),
          if (hint != null)
            Positioned(
              left: 16,
              right: 16,
              top: 40,
              child: Text(
                hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 20),
              ),
            ),
          Positioned(
            left: 10,
            right: 0,
            bottom: _boardHeight * 0.58 + 4,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: books.map(_spine).toList(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _boardHeight,
            child: CustomPaint(painter: _BoardPainter()),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B110A),
      appBar: AppBar(
        title: const Text('My Bookcase', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.orange.shade100,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '🔥 ${Store.streak} day streak',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPdf,
        icon: const Icon(Icons.add),
        label: const Text('Add PDF', style: TextStyle(fontSize: 20)),
      ),
      body: LayoutBuilder(builder: (context, box) {
        const outer = 10.0;
        const frame = 16.0;
        final avail = box.maxWidth - 2 * outer - 2 * frame - 10;
        final rows = _rows(avail);
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(outer, 12, outer, 110),
          child: Container(
            padding: const EdgeInsets.all(frame),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color(0xFF4A2E18),
                  Color(0xFF8A5A33),
                  Color(0xFF6A4223),
                  Color(0xFF8A5A33),
                  Color(0xFF4A2E18),
                ],
              ),
              boxShadow: const [
                BoxShadow(color: Colors.black87, blurRadius: 14, offset: Offset(0, 6)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++)
                    _shelf(
                      rows[i],
                      hint: (i == 0 && Store.books.isEmpty)
                          ? 'Your bookcase is empty.\nTap "Add PDF" to put your first book here.'
                          : null,
                    ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// A wooden shelf board seen slightly from above: lit top face + darker front edge.
class _BoardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final topH = size.height * 0.58;
    const inset = 16.0;
    final topRect = Rect.fromLTWH(0, 0, size.width, topH);
    final top = Path()
      ..moveTo(inset, 0)
      ..lineTo(size.width - inset, 0)
      ..lineTo(size.width, topH)
      ..lineTo(0, topH)
      ..close();
    canvas.drawPath(
      top,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF6B4527), Color(0xFFB98350)],
        ).createShader(topRect),
    );
    final front = Rect.fromLTWH(0, topH, size.width, size.height - topH);
    canvas.drawRect(
      front,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF9A6A3E), Color(0xFF4A2E18)],
        ).createShader(front),
    );
    canvas.drawLine(
      Offset(0, topH),
      Offset(size.width, topH),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..strokeWidth = 1.5,
    );
    final grain = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = topH + front.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grain);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------- reader

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});
  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with SingleTickerProviderStateMixin {
  static const _paperEdge = EdgeInsets.symmetric(horizontal: 8, vertical: 10);

  PdfDocument? _doc;
  final AudioPlayer _player = AudioPlayer();
  final Map<int, Future<Uint8List?>> _cache = {};
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Animatable<double>? _tween;

  int _page = 0; // page shown when nothing is turning
  int? _t; // index of the page that is currently turning
  double _p = 0; // 0 = page flat on the right, 1 = fully turned over
  double? _drag;
  String? _error;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() {
      final tw = _tween;
      if (tw != null) setState(() => _p = tw.evaluate(_anim));
    });
    _openDoc();
  }

  Future<void> _openDoc() async {
    try {
      final d = await PdfDocument.openFile(widget.book.path);
      final start = min(max(widget.book.lastPage, 0), max(0, d.pagesCount - 1));
      widget.book.pages = d.pagesCount;
      await Store.save();
      await Store.markReadToday();
      if (!mounted) return;
      setState(() {
        _doc = d;
        _page = start;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Sorry, this PDF could not be opened.');
    }
  }

  Future<Uint8List?> _render(int i) async {
    final p = await _doc!.getPage(i + 1);
    try {
      final img = await p.render(
        width: p.width * 2,
        height: p.height * 2,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#FFFFFF',
      );
      return img?.bytes;
    } finally {
      await p.close();
    }
  }

  void _commit(int newPage) {
    _t = null;
    _p = 0;
    _page = newPage;
    widget.book.lastPage = newPage;
    Store.save();
    Store.markReadToday();
    _cache.removeWhere((k, _) => (k - newPage).abs() > 4);
    setState(() {});
  }

  void _settle(double target) {
    final t = _t;
    if (t == null) return;
    final newPage = target >= 1.0 ? t + 1 : t;
    if (newPage != _page) _player.play(AssetSource('page.wav'));
    _tween = Tween<double>(begin: _p, end: target)
        .chain(CurveTween(curve: Curves.easeOutCubic));
    _anim.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _tween = null;
      _commit(newPage);
    });
  }

  double _c01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  Widget _image(int i) {
    return FutureBuilder<Uint8List?>(
      future: _cache.putIfAbsent(i, () => _render(i)),
      builder: (c, s) {
        if (s.hasData && s.data != null) {
          return Image.memory(s.data!, fit: BoxFit.contain, gaplessPlayback: true);
        }
        if (s.connectionState == ConnectionState.done) {
          return const Center(
              child: Text('This page could not load', style: TextStyle(fontSize: 20)));
        }
        return const Center(child: CircularProgressIndicator());
      },
    );
  }

  Widget _paper(int i) {
    return Container(
      margin: _paperEdge,
      color: Colors.white,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _image(i),
          // shade near the spine, like paper curving into the binding
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 22,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black.withOpacity(0.22), Colors.black.withOpacity(0)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The page underneath that is revealed as the top page lifts away.
  Widget _underPage(int i, double p) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _paper(i),
        IgnorePointer(
          child: Container(
            margin: _paperEdge,
            color: Colors.black.withOpacity(0.32 * sin(p * pi)),
          ),
        ),
      ],
    );
  }

  /// The page that folds over from the spine (left edge) with perspective and shadow.
  Widget _turningPage(int i, double p) {
    final m = Matrix4.identity()
      ..setEntry(3, 2, 0.0014)
      ..rotateY(-p * pi);
    final seenFromBehind = p > 0.5;
    return Transform(
      alignment: Alignment.centerLeft,
      transform: m,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _paper(i),
          if (seenFromBehind)
            Container(margin: _paperEdge, color: const Color(0xE6F1E8D6)),
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                margin: _paperEdge,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      Colors.black.withOpacity(0),
                      Colors.black.withOpacity(0.3 * sin(p * pi)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _flipView(PdfDocument doc) {
    final n = doc.pagesCount;
    for (final i in [_page - 1, _page, _page + 1, _page + 2]) {
      if (i >= 0 && i < n) _cache.putIfAbsent(i, () => _render(i));
    }
    return LayoutBuilder(builder: (c, box) {
      final w = box.maxWidth;
      final t = _t ?? _page;
      final p = _t == null ? 0.0 : _p;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (_t != null || _anim.isAnimating) return;
          if (d.localPosition.dx > w / 2 && _page < n - 1) {
            setState(() {
              _t = _page;
              _p = 0;
            });
            _settle(1.0);
          } else if (d.localPosition.dx <= w / 2 && _page > 0) {
            setState(() {
              _t = _page - 1;
              _p = 1;
            });
            _settle(0.0);
          }
        },
        onHorizontalDragUpdate: (d) {
          if (_anim.isAnimating) return;
          if (_t == null) {
            if (d.delta.dx < 0 && _page < n - 1) {
              _t = _page;
              _p = 0;
            } else if (d.delta.dx > 0 && _page > 0) {
              _t = _page - 1;
              _p = 1;
            } else {
              return;
            }
          }
          setState(() => _p = _c01(_p - d.delta.dx / (w * 0.85)));
        },
        onHorizontalDragEnd: (d) {
          if (_t == null || _anim.isAnimating) return;
          final v = d.primaryVelocity ?? 0;
          final target = v < -400 ? 1.0 : (v > 400 ? 0.0 : (_p >= 0.5 ? 1.0 : 0.0));
          _settle(target);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (t + 1 < n) _underPage(t + 1, p),
            _turningPage(t, p),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _doc?.close();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final night = Store.night;
    final doc = _doc;

    Widget body;
    if (_error != null) {
      body = Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, color: Colors.white)),
      ));
    } else if (doc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      Widget pages = _flipView(doc);
      if (night) {
        pages = ColorFiltered(
          colorFilter: const ColorFilter.mode(Color(0xFFD9A066), BlendMode.multiply),
          child: pages,
        );
      }
      body = pages;
    }

    final shownPage = _t == null ? _page : (_p >= 0.5 ? _t! + 1 : _t!);

    return Scaffold(
      backgroundColor: night ? const Color(0xFF140E08) : const Color(0xFF4A3426),
      appBar: AppBar(
        title: Text(widget.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            iconSize: 30,
            tooltip: night ? 'Day mode' : 'Night mode',
            icon: Icon(night ? Icons.wb_sunny : Icons.nightlight_round),
            onPressed: () async {
              Store.night = !Store.night;
              await Store.save();
              setState(() {});
            },
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: doc == null
          ? null
          : Container(
              color: night ? const Color(0xFF1F160E) : const Color(0xFF2E1F14),
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Page ${shownPage + 1} of ${doc.pagesCount}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    if (doc.pagesCount > 1)
                      Slider(
                        min: 0,
                        max: (doc.pagesCount - 1).toDouble(),
                        value: min(max(_drag ?? _page.toDouble(), 0.0),
                            (doc.pagesCount - 1).toDouble()),
                        onChanged: (v) => setState(() => _drag = v),
                        onChangeEnd: (v) {
                          setState(() => _drag = null);
                          final target = v.round();
                          if (target != _page && _t == null) {
                            _player.play(AssetSource('page.wav'));
                            _commit(target);
                          }
                        },
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
