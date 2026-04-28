import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:classroom_app/core/constants/app_colors.dart';
import '../services/agora_engine.dart';
import './widgets/agora_video_view_wrapper.dart';
import '../providers/live_class_provider.dart';
import '../../auth/providers/auth_provider.dart';

class LiveStreamScreen extends ConsumerStatefulWidget {
  final String classId;

  const LiveStreamScreen({super.key, required this.classId});

  @override
  ConsumerState<LiveStreamScreen> createState() => _LiveStreamScreenState();
}

class _LiveStreamScreenState extends ConsumerState<LiveStreamScreen> {
  late AgoraEngine _agoraEngine;

  int? _remoteUid;
  bool _localUserJoined = false;

  bool isMicMuted = false;
  bool isCameraOff = false;

  bool _isLoading = true;
  String? _error;

  String? _token;
  String? _meetingId;
  String? _role;

  @override
  void initState() {
    super.initState();
    _agoraEngine = AgoraEngine();
    _connectToClass();
  }

  @override
  void dispose() {
    _agoraEngine.dispose();
    super.dispose();
  }

  // ========================= CONNECT =========================

  Future<void> _connectToClass() async {
    try {
      final isTeacher = ref.read(authProvider).role == 'TEACHER';
      final liveProvider = ref.read(liveClassesProvider.notifier);

      if (!isTeacher) {
        final joinRes = await liveProvider.joinClass(widget.classId);
        if (joinRes == null) throw Exception("Join failed");
      }

      final tokenRes = await liveProvider.getClassToken(widget.classId);
      if (tokenRes == null) throw Exception("Token failed");

      _token = tokenRes['token'];
      _meetingId = tokenRes['meetingId'] ?? tokenRes['channel'];
      _role = isTeacher ? 'PUBLISHER' : 'SUBSCRIBER';

      // 🔥 CRITICAL FIX (race condition)
      await Future.delayed(const Duration(milliseconds: 500));

      await _initAgora(tokenRes['appId']);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  // ========================= INIT =========================

  Future<void> _initAgora(String appId) async {
    if (!kIsWeb) {
      await [Permission.microphone, Permission.camera].request();
    }

    await _agoraEngine.initialize(appId);

    _agoraEngine.onRemoteUserJoined = (uid) {
      setState(() => _remoteUid = uid);
    };

    _agoraEngine.onRemoteUserOffline = () {
      setState(() => _remoteUid = null);
    };

    await _agoraEngine.joinChannel(_token!, _meetingId!, _role!);

    final isTeacher = ref.read(authProvider).role == 'TEACHER';

    // 🔥 STUDENT FIX (no camera)
    if (!isTeacher) {
      await _agoraEngine.muteLocalVideoStream(true);
      await _agoraEngine.muteLocalAudioStream(false);
    }

    setState(() {
      _localUserJoined = true;
      _isLoading = false;
    });
  }

  // ========================= UI =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _mainVideo()),

          if (_localUserJoined && _isTeacher())
            Positioned(
              top: 20,
              right: 20,
              child: _localPreview(),
            ),

          if (_isLoading) _loadingUI(),
          if (_error != null) _errorUI(),

          _topBar(),
          _controls(),
        ],
      ),
    );
  }

  // ========================= VIDEO LOGIC =========================

  bool _isTeacher() => ref.read(authProvider).role == 'TEACHER';

  Widget _mainVideo() {
    if (_isTeacher()) {
      if (!_localUserJoined) {
        return _placeholder("Starting camera...");
      }

      return AgoraVideoViewWrapper(
        engine: _agoraEngine.localVideoView,
        isLocal: true,
        webElementId: kIsWeb ? 'local-video' : null,
      );
    }

    if (_remoteUid != null) {
      return AgoraVideoViewWrapper(
        engine: _agoraEngine.remoteVideoView,
        remoteUid: _remoteUid,
        webElementId: kIsWeb ? 'remote-video' : null,
      );
    }

    return _placeholder("Waiting for teacher...");
  }

  Widget _localPreview() {
    return Container(
      width: 120,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.black,
      ),
      child: AgoraVideoViewWrapper(
        engine: _agoraEngine.localVideoView,
        isLocal: true,
        webElementId: kIsWeb ? 'local-video' : null,
      ),
    );
  }

  // ========================= CONTROLS =========================

  Widget _controls() {
    return Positioned(
      bottom: 40,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _btn(
            isMicMuted ? Icons.mic_off : Icons.mic,
            isMicMuted ? Colors.red : Colors.white,
            _toggleMic,
            'mic_btn',
          ),
          const SizedBox(width: 20),
          FloatingActionButton.large(
            heroTag: 'end_btn',
            backgroundColor: Colors.red,
            onPressed: _leaveClass,
            child: const Icon(Icons.call_end, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 20),
          _btn(
            isCameraOff ? Icons.videocam_off : Icons.videocam,
            isCameraOff ? Colors.red : Colors.white,
            _toggleCamera,
            'cam_btn',
          ),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, Color color, VoidCallback onTap, String tag) {
    return FloatingActionButton(
      heroTag: tag,
      onPressed: onTap,
      backgroundColor: color,
      child: Icon(icon, color: color == Colors.red ? Colors.white : Colors.black),
    );
  }

  // ========================= ACTIONS =========================

  void _toggleMic() async {
    final newState = !isMicMuted;
    await _agoraEngine.muteLocalAudioStream(newState);
    setState(() => isMicMuted = newState);
  }

  void _toggleCamera() async {
    final newState = !isCameraOff;
    await _agoraEngine.muteLocalVideoStream(newState);
    setState(() => isCameraOff = newState);
  }

  Future<void> _leaveClass() async {
    await _agoraEngine.leaveChannel();
    await ref.read(liveClassesProvider.notifier).leaveClass(widget.classId);
    if (mounted) context.pop();
  }

  // ========================= UI HELPERS =========================

  Widget _loadingUI() {
    return Container(
      color: Colors.black,
      child: const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      ),
    );
  }

  Widget _errorUI() {
    return Center(
      child: Text(_error!, style: const TextStyle(color: Colors.white)),
    );
  }

  Widget _placeholder(String text) {
    return Center(
      child: Text(text, style: const TextStyle(color: Colors.white)),
    );
  }

  Widget _topBar() {
    return Positioned(
      top: 30,
      left: 10,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _leaveClass,
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Live Class",
                  style: TextStyle(color: Colors.white)),
              Text(_meetingId ?? '',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ],
      ),
    );
  }
}
