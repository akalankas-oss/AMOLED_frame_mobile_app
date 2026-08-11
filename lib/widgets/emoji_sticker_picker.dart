import 'package:flutter/material.dart';

class EmojiStickerPicker extends StatefulWidget {
  final ValueChanged<String> onEmojiPicked;
  final ValueChanged<IconData> onStickerPicked;

  const EmojiStickerPicker({
    super.key,
    required this.onEmojiPicked,
    required this.onStickerPicked,
  });

  @override
  State<EmojiStickerPicker> createState() => _EmojiStickerPickerState();
}

class _EmojiStickerPickerState extends State<EmojiStickerPicker> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const Map<String, List<String>> _emojiCategories = {
    'Smileys': [
      '😀', '😁', '😂', '🤣', '😊', '😍', '😘', '😜', '🤪', '😎',
      '🥳', '😇', '🙃', '🤩', '😢', '😭', '😡', '🤔', '😴', '🤗',
      '😏', '😅', '🥰', '😋', '🤤', '😱', '🥺', '😤', '🤯', '🥶',
    ],
    'Hands & Hearts': [
      '👍', '👎', '👏', '🙌', '🤝', '💪', '✌️', '🤞', '👌', '🤙',
      '👋', '🤟', '🫶', '✋', '🖐️', '🙏',
      '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '💔', '💯',
      '💕', '💖', '💗', '💞',
    ],
    'Nature': [
      '🌸', '🌺', '🌻', '🌈', '☀️', '🌙', '⚡', '❄️', '🍀', '🌊',
      '🐶', '🐱', '🐼', '🦄', '🐝', '🦋', '🐾', '🐦', '🐟', '🦁',
      '🌵', '🌴', '🍁', '🌹', '⭐', '🌟', '💫', '☁️',
    ],
    'Food': [
      '🍕', '🍔', '🍰', '🎂', '☕', '🍦', '🍩', '🍓', '🍉', '🥑',
      '🍎', '🍇', '🍒', '🍫', '🍿', '🌮', '🍟', '🍪',
    ],
    'Objects': [
      '📷', '🎮', '🎵', '🎨', '📚', '✈️', '🚀', '⚽', '🎯', '💡',
      '🎉', '🎊', '🎈', '🎁', '🏆', '🔥', '✨', '💰', '⏰', '📱',
    ],
  };

  static const List<IconData> _stickerIcons = [
    Icons.star, Icons.favorite, Icons.brightness_5, Icons.celebration,
    Icons.pets, Icons.wb_sunny, Icons.auto_awesome, Icons.music_note,
    Icons.local_pizza, Icons.cake, Icons.videogame_asset, Icons.rocket_launch,
    Icons.emoji_emotions, Icons.mood, Icons.thumb_up, Icons.diamond,
    Icons.local_fire_department, Icons.bolt, Icons.anchor, Icons.spa,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _emojiCategories.length + 1, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Widget _buildEmojiGrid(List<String> emojis) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: emojis.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => widget.onEmojiPicked(emojis[idx]),
        child: Center(child: Text(emojis[idx], style: const TextStyle(fontSize: 24))),
      ),
    );
  }

  Widget _buildStickerGrid() {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: _stickerIcons.length,
      itemBuilder: (ctx, idx) => InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => widget.onStickerPicked(_stickerIcons[idx]),
        child: Center(child: Icon(_stickerIcons[idx], color: Colors.amberAccent, size: 22)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoryNames = _emojiCategories.keys.toList();
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: Colors.amberAccent,
            unselectedLabelColor: Colors.white54,
            indicatorColor: Colors.amberAccent,
            tabs: [
              ...categoryNames.map((name) => Tab(text: name)),
              const Tab(icon: Icon(Icons.emoji_emotions_outlined), text: 'Stickers'),
            ],
          ),
          SizedBox(
            height: 190,
            child: TabBarView(
              controller: _tabController,
              children: [
                ...categoryNames.map((name) => _buildEmojiGrid(_emojiCategories[name]!)),
                _buildStickerGrid(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
