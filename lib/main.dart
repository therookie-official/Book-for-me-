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
  ];

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

  Widget _cover(Book b) {
    final color = _coverColors[b.id.hashCode.abs() % _coverColors.length];
    return GestureDetector(
      onTap: () => _open(b),
      onLongPress: () => _confirmRemove(b),
      child: Container(
        height: 180,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            topRight: Radius.circular(8),
          ),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(2, 0)),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Center(
                child: Text(
                  b.title,
                  textAlign: TextAlign.center,
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            if (b.pages > 0)
              Text(
                'Page ${b.lastPage + 1}/${b.pages}',
                style: const TextStyle(color: Colors.white70, fontSize: 15),
              ),
          ],
        ),
      ),
    );
  }

  Widget _board() => Container(
        height: 16,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF9A6B43), Color(0xFF5E3D22)],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final rowCount = max(3, (Store.books.length / 3).ceil() + 1);
    return Scaffold(
      backgroundColor: const Color(0xFF3A2616),
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
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(10, 16, 10, 100),
        itemCount: rowCount,
        itemBuilder: (c, row) {
          final start = row * 3;
          final slots = <Widget>[];
          for (var i = start; i < start + 3; i++) {
            slots.add(Expanded(
              child: i < Store.books.length
                  ? _cover(Store.books[i])
                  : const SizedBox(height: 180),
            ));
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              children: [
                if (row == 0 && Store.books.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Your shelf is empty.\nTap "Add PDF" to put your first book here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 20),
                    ),
                  ),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: slots),
                _board(),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------- reader

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.book});
  final Book book;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  PdfDocument? _doc;
  PageController? _pc;
  final AudioPlayer _player = AudioPlayer();
  final Map<int, Future<Uint8List?>> _cache = {};
  int _page = 0;
  double? _drag;
  String? _error;

  @override
  void initState() {
    super.initState();
    _openDoc();
  }

  Future<void> _openDoc() async {
    try {
      final d = await PdfDocument.openFile(widget.book.path);
      final start = widget.book.lastPage.clamp(0, max(0, d.pagesCount - 1)).toInt();
      widget.book.pages = d.pagesCount;
      await Store.save();
      await Store.markReadToday();
      if (!mounted) return;
      setState(() {
        _doc = d;
        _page = start;
        _pc = PageController(initialPage: start);
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

  void _changed(int i) {
    if (i == _page) return;
    _page = i;
    widget.book.lastPage = i;
    Store.save();
    Store.markReadToday();
    _player.play(AssetSource('page.wav'));
    _cache.removeWhere((k, _) => (k - i).abs() > 4);
    setState(() {});
  }

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

  /// One page that folds away from its left edge like a real page being turned.
  Widget _pageTile(int i) {
    final pc = _pc!;
    return AnimatedBuilder(
      animation: pc,
      builder: (c, _) {
        double v = 0;
        if (pc.hasClients && pc.position.haveDimensions) {
          v = (pc.page ?? i.toDouble()) - i;
        }
        final t = v.clamp(0.0, 1.0);
        final m = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateY(-t * 1.1);
        return Transform(
          alignment: Alignment.centerLeft,
          transform: m,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                color: Colors.white,
                child: _image(i),
              ),
              if (v != 0)
                IgnorePointer(
                  child: Container(
                    color: Colors.black.withOpacity(v.abs().clamp(0.0, 1.0) * 0.35),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _pc?.dispose();
    _doc?.close();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final night = Store.night;
    final doc = _doc;
    final pc = _pc;

    Widget body;
    if (_error != null) {
      body = Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(_error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 22, color: Colors.white)),
      ));
    } else if (doc == null || pc == null) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      Widget pages = PageView.builder(
        controller: pc,
        itemCount: doc.pagesCount,
        onPageChanged: _changed,
        itemBuilder: (c, i) => _pageTile(i),
      );
      if (night) {
        pages = ColorFiltered(
          colorFilter: const ColorFilter.mode(Color(0xFFD9A066), BlendMode.multiply),
          child: pages,
        );
      }
      body = pages;
    }

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
      bottomNavigationBar: (doc == null || pc == null)
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
                      'Page ${_page + 1} of ${doc.pagesCount}',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    if (doc.pagesCount > 1)
                      Slider(
                        min: 0,
                        max: (doc.pagesCount - 1).toDouble(),
                        value: (_drag ?? _page.toDouble())
                            .clamp(0, (doc.pagesCount - 1).toDouble())
                            .toDouble(),
                        onChanged: (v) => setState(() => _drag = v),
                        onChangeEnd: (v) {
                          setState(() => _drag = null);
                          pc.jumpToPage(v.round());
                        },
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}
