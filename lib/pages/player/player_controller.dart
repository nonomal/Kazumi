import 'dart:io';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:mobx/mobx.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:kazumi/request/damaku.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:hive/hive.dart';
import 'package:kazumi/utils/storage.dart';
import 'package:logger/logger.dart';
import 'package:kazumi/utils/logger.dart';
import 'package:kazumi/utils/utils.dart';

part 'player_controller.g.dart';

class PlayerController = _PlayerController with _$PlayerController;

abstract class _PlayerController with Store {
  @observable
  bool loading = true;

  String videoUrl = '';
  // dandanPlay弹幕ID
  int bangumiID = 0;
  late Player mediaPlayer;
  late VideoController videoController;
  late DanmakuController danmakuController;
  final VideoPageController videoPageController =
      Modular.get<VideoPageController>();

  @observable
  Map<int, List<Danmaku>> danDanmakus = {};

  @observable
  bool playing = false;
  @observable
  bool isBuffering = true;
  @observable
  bool completed = false;
  @observable
  Duration currentPosition = Duration.zero;
  @observable
  Duration buffer = Duration.zero;
  @observable
  Duration duration = Duration.zero;

  // 弹幕开关
  @observable
  bool danmakuOn = false;

  // 视频比例类型
  // 1. AUTO
  // 2. COVER
  // 3. FILL
  @observable
  int aspectRatioType = 1;

  // 视频音量/亮度
  @observable
  double volume = 0;
  @observable
  double brightness = 0;

  // 播放器倍速
  @observable
  double playerSpeed = 1.0;

  Box setting = GStorage.setting;
  bool hAenable = true;
  bool lowMemoryMode = false;
  bool autoPlay = true;

  Future<void> init({int offset = 0}) async {
    playing = false;
    loading = true;
    isBuffering = true;
    currentPosition = Duration.zero;
    buffer = Duration.zero;
    duration = Duration.zero;
    completed = false;
    try {
      mediaPlayer.dispose();
    } catch (_) {}
    KazumiLogger().log(Level.info, 'VideoItem开始初始化');
    int episodeFromTitle = 0;
    try {
      episodeFromTitle = Utils.extractEpisodeNumber(videoPageController
          .roadList[videoPageController.currentRoad]
          .identifier[videoPageController.currentEpisode - 1]);
    } catch (e) {
      KazumiLogger().log(Level.error, '从标题解析集数错误 ${e.toString()}');
    }
    if (episodeFromTitle == 0) {
      episodeFromTitle = videoPageController.currentEpisode;
    }
    getDanDanmaku(videoPageController.title, episodeFromTitle);
    mediaPlayer = await createVideoController(offset: offset);
    playerSpeed =
        setting.get(SettingBoxKey.defaultPlaySpeed, defaultValue: 1.0);
    setPlaybackSpeed(playerSpeed);
    KazumiLogger().log(Level.info, 'VideoURL初始化完成');
    loading = false;
  }

  Future<Player> createVideoController({int offset = 0}) async {
    String userAgent = '';
    hAenable = setting.get(SettingBoxKey.hAenable, defaultValue: true);
    autoPlay = setting.get(SettingBoxKey.autoPlay, defaultValue: true);
    lowMemoryMode =
        setting.get(SettingBoxKey.lowMemoryMode, defaultValue: false);
    if (videoPageController.currentPlugin.userAgent == '') {
      userAgent = Utils.getRandomUA();
    } else {
      userAgent = videoPageController.currentPlugin.userAgent;
    }
    KazumiLogger().log(Level.info, 'media_kit UA: $userAgent');
    String referer = videoPageController.currentPlugin.referer;
    KazumiLogger().log(Level.info, 'media_kit Referer: $referer');
    var httpHeaders = {
      'user-agent': userAgent,
      if (referer.isNotEmpty) 'referer': referer,
    };

    mediaPlayer = Player(
      configuration: PlayerConfiguration(
        bufferSize: lowMemoryMode ? 15 * 1024 * 1024 : 1500 * 1024 * 1024,
      ),
    );

    var pp = mediaPlayer.platform as NativePlayer;
    await pp.setProperty("af", "scaletempo2=max-speed=8");
    if (Platform.isAndroid) {
      await pp.setProperty("volume-max", "100");
      await pp.setProperty("ao", "audiotrack,opensles");
    }

    await mediaPlayer.setAudioTrack(
      AudioTrack.auto(),
    );

    videoController = VideoController(
      mediaPlayer,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: hAenable,
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    mediaPlayer.setPlaylistMode(PlaylistMode.none);

    // error handle
    mediaPlayer.stream.error.listen((event) {
      SmartDialog.showToast('播放器内部错误 ${event.toString()} $videoUrl',
          displayTime: const Duration(seconds: 5),
          displayType: SmartToastType.onlyRefresh);
      KazumiLogger().log(
          Level.error, 'Player intent error: ${event.toString()} $videoUrl');
    });

    await mediaPlayer.open(
      Media(videoUrl,
          start: Duration(seconds: offset), httpHeaders: httpHeaders),
      play: autoPlay,
    );

    return mediaPlayer;
  }

  Future<void> setPlaybackSpeed(double playerSpeed) async {
    this.playerSpeed = playerSpeed;
    try {
      mediaPlayer.setRate(playerSpeed);
    } catch (e) {
      KazumiLogger().log(Level.error, '设置播放速度失败 ${e.toString()}');
    }
  }

  Future<void> playOrPause() async {
    if (mediaPlayer.state.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seek(Duration duration) async {
    danmakuController.clear();
    await mediaPlayer.seek(duration);
  }

  Future<void> pause() async {
    danmakuController.pause();
    await mediaPlayer.pause();
    playing = false;
  }

  Future<void> play() async {
    danmakuController.resume();
    await mediaPlayer.play();
    playing = true;
  }

  Future<void> getDanDanmaku(String title, int episode) async {
    KazumiLogger().log(Level.info, '尝试获取弹幕 $title');
    try {
      danDanmakus.clear();
      bangumiID = await DanmakuRequest.getBangumiID(title);
      var res = await DanmakuRequest.getDanDanmaku(bangumiID, episode);
      addDanmakus(res);
    } catch (e) {
      KazumiLogger().log(Level.warning, '获取弹幕错误 ${e.toString()}');
    }
  }

  Future<void> getDanDanmakuByEpisodeID(int episodeID) async {
    KazumiLogger().log(Level.info, '尝试获取弹幕 $episodeID');
    try {
      danDanmakus.clear();
      var res = await DanmakuRequest.getDanDanmakuByEpisodeID(episodeID);
      addDanmakus(res);
    } catch (e) {
      KazumiLogger().log(Level.warning, '获取弹幕错误 ${e.toString()}');
    }
  }

  void addDanmakus(List<Danmaku> danmakus) {
    for (var element in danmakus) {
      var danmakuList =
          danDanmakus[element.time.toInt()] ?? List.empty(growable: true);
      danmakuList.add(element);
      danDanmakus[element.time.toInt()] = danmakuList;
    }
  }
}
