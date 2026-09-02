import 'package:flutter/material.dart';

class EmojiStickerPicker extends StatelessWidget {
  final ValueChanged<IconData> onStickerPicked;

  const EmojiStickerPicker({
    super.key,
    required this.onStickerPicked,
  });

  static const List<IconData> _stickerIcons = [
    Icons.star, Icons.favorite, Icons.brightness_5, Icons.celebration,
    Icons.pets, Icons.wb_sunny, Icons.auto_awesome, Icons.music_note,
    Icons.local_pizza, Icons.cake, Icons.videogame_asset, Icons.rocket_launch,
    Icons.emoji_emotions, Icons.mood, Icons.thumb_up, Icons.diamond,
    Icons.local_fire_department, Icons.bolt, Icons.anchor, Icons.spa,
  ];

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
        onTap: () => onStickerPicked(_stickerIcons[idx]),
        child: Center(child: Icon(_stickerIcons[idx], color: Colors.amberAccent, size: 22)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: Text('Stickers', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold)),
          ),
          SizedBox(
            height: 190,
            child: _buildStickerGrid(),
          ),
        ],
      ),
    );
  }
}

