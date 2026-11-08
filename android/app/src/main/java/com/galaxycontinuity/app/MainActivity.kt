package com.galaxycontinuity.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.galaxycontinuity.app.service.ContinuityService
import com.galaxycontinuity.app.service.ScreenMirroringService

class MainActivity : ComponentActivity() {

    // Register ActivityResultLauncher for MediaProjection
    private val projectionLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        Log.i("MainActivity", "projectionLauncher callback received resultCode=${result.resultCode}, data=${result.data}")
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val serviceIntent = Intent(this, ScreenMirroringService::class.java).apply {
                action = ScreenMirroringService.ACTION_START
                putExtra(ScreenMirroringService.EXTRA_RESULT_CODE, result.resultCode)
                putExtra(ScreenMirroringService.EXTRA_RESULT_DATA, result.data)
                putExtra(ScreenMirroringService.EXTRA_WIDTH, 720)
                putExtra(ScreenMirroringService.EXTRA_HEIGHT, 1600)
                putExtra(ScreenMirroringService.EXTRA_FPS, 30)
                putExtra(ScreenMirroringService.EXTRA_BITRATE, 3000000)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(serviceIntent)
            } else {
                startService(serviceIntent)
            }
        }
    }

    // Function to launch screen capture consent dialog
    fun requestScreenCapture() {
        Log.i("MainActivity", "requestScreenCapture() called")
        val mpManager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (mpManager == null) {
            Log.e("MainActivity", "MediaProjectionManager is null!")
            return
        }
        val captureIntent = mpManager.createScreenCaptureIntent()
        Log.i("MainActivity", "Launching createScreenCaptureIntent: $captureIntent")
        projectionLauncher.launch(captureIntent)
    }

    // Function to open Android Accessibility settings
    fun openAccessibilitySettings() {
        val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        startActivity(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        handleIntent(intent)

        // Start service
        val serviceIntent = Intent(this, ContinuityService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent)
        } else {
            startService(serviceIntent)
        }

        setContent {
            MaterialTheme(
                colorScheme = darkColorScheme(
                    background = Color(0xFF0F172A),
                    surface = Color(0xFF1E293B),
                    primary = Color(0xFF0381FE)
                )
            ) {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ContinuityScreen(
                        onRequestScreenCapture = { requestScreenCapture() },
                        onOpenAccessibility = { openAccessibilitySettings() }
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == "com.galaxycontinuity.app.REQUEST_SCREEN_CAPTURE") {
            requestScreenCapture()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContinuityScreen(
    onRequestScreenCapture: () -> Unit = {},
    onOpenAccessibility: () -> Unit = {}
) {
    val isConnected by ContinuityService.isSocketConnected.collectAsState()
    val statusText by ContinuityService.connectionStatus.collectAsState()
    var hostIp by remember { mutableStateOf("127.0.0.1") }
    var textToSend by remember { mutableStateOf("") }

    // Proactively try connecting when screen loads
    LaunchedEffect(Unit) {
        ContinuityService.connectManually("127.0.0.1", 8765)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        // App Bar / Title
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column {
                Text(
                    text = "Galaxy Continuity",
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    text = "Samsung + Mac Bridge",
                    fontSize = 13.sp,
                    color = Color(0xFF94A3B8)
                )
            }

            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(20.dp))
                    .background(if (isConnected) Color(0xFF065F46) else Color(0xFF334155))
                    .padding(horizontal = 12.dp, vertical = 6.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(if (isConnected) Color(0xFF10B981) else Color(0xFFEF4444))
                    )
                    Text(
                        text = if (isConnected) "Connected" else "Searching...",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(4.dp))

        // Status & Connection Card
        Card(
            shape = RoundedCornerShape(18.dp),
            colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B)),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Laptop,
                        contentDescription = "Mac",
                        tint = Color(0xFF0381FE),
                        modifier = Modifier.size(28.dp)
                    )
                    Column {
                        Text(
                            text = "macOS Companion",
                            fontWeight = FontWeight.Bold,
                            fontSize = 15.sp,
                            color = Color.White
                        )
                        Text(
                            text = statusText,
                            fontSize = 12.sp,
                            color = Color(0xFF94A3B8)
                        )
                    }
                }

                if (!isConnected) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        OutlinedTextField(
                            value = hostIp,
                            onValueChange = { hostIp = it },
                            placeholder = { Text("IP (127.0.0.1 for USB)") },
                            modifier = Modifier.weight(1f),
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = Color.White,
                                unfocusedTextColor = Color.White,
                                focusedBorderColor = Color(0xFF0381FE),
                                unfocusedBorderColor = Color(0xFF334155)
                            ),
                            shape = RoundedCornerShape(10.dp)
                        )
                        Button(
                            onClick = {
                                ContinuityService.connectManually(hostIp.trim(), 8765)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0381FE)),
                            shape = RoundedCornerShape(10.dp)
                        ) {
                            Text("Connect")
                        }
                    }
                }
            }
        }

        // Universal Clipboard Card
        Card(
            shape = RoundedCornerShape(18.dp),
            colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B)),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.ContentPaste,
                        contentDescription = "Clipboard",
                        tint = Color(0xFF38BDF8)
                    )
                    Text(
                        text = "Universal Clipboard",
                        fontWeight = FontWeight.Bold,
                        fontSize = 15.sp,
                        color = Color.White
                    )
                }

                OutlinedTextField(
                    value = textToSend,
                    onValueChange = { textToSend = it },
                    placeholder = { Text("Paste or type text to send to Mac...") },
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color(0xFF0381FE),
                        unfocusedBorderColor = Color(0xFF334155),
                        focusedTextColor = Color.White,
                        unfocusedTextColor = Color.White
                    ),
                    shape = RoundedCornerShape(12.dp)
                )

                Button(
                    onClick = {
                        if (textToSend.isNotEmpty()) {
                            ContinuityService.activeClient?.sendClipboard(textToSend)
                            textToSend = ""
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF0381FE))
                ) {
                    Icon(Icons.Default.Send, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Push to Mac Clipboard")
                }
            }
        }

        // Continuity Controls (Screen Mirroring & Accessibility)
        Card(
            shape = RoundedCornerShape(18.dp),
            colors = CardDefaults.cardColors(containerColor = Color(0xFF1E293B)),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(
                modifier = Modifier.padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = "Continuity Features",
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    color = Color.White
                )

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    OutlinedButton(
                        onClick = onRequestScreenCapture,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        Text("Mirror Screen", fontSize = 12.sp)
                    }

                    OutlinedButton(
                        onClick = onOpenAccessibility,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        Text("Remote Input", fontSize = 12.sp)
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp)
                ) {
                    OutlinedButton(
                        onClick = {
                            ContinuityService.activeClient?.sendNotification(
                                "Samsung Galaxy",
                                "Galaxy Test",
                                "Testing notifications from Galaxy to Mac!"
                            )
                        },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp)
                    ) {
                        Text("Test Notify", fontSize = 12.sp)
                    }
                }
            }
        }
    }
}
