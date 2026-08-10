const crypto = require('crypto');
const express = require('express');
const axios = require('axios');
const router = express.Router();
const Wallet = require('../models/Wallet');
const Transaction = require('../models/Transaction');
const { sendTelegramMessage } = require('../services/telegram');

const DEFAULT_PAYMENT_CONFIG = {
  merchantId: 'voicevision-demo-merchant',
  merchantDisplayName: 'VoiceVision Demo Merchant',
  recipientPhone: '8290883601',
  trustedQrRaw: 'https://en.m.wikipedia.org',
  maxPerTxnAmount: 5000
};

function normalizeQRRaw(raw) {
  if (typeof raw !== 'string') return '';
  let normalized = raw.trim().toLowerCase();
  if (normalized.startsWith('https://')) normalized = normalized.slice('https://'.length);
  if (normalized.startsWith('http://')) normalized = normalized.slice('http://'.length);
  if (normalized.endsWith('/')) normalized = normalized.slice(0, -1);
  return normalized;
}

function fingerprintQR(raw) {
  const normalized = normalizeQRRaw(raw);
  return crypto.createHash('sha256').update(normalized).digest('hex');
}

function parsePositiveAmount(value) {
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount <= 0) return null;
  return Math.round(amount * 100) / 100;
}

function getPaymentConfig() {
  const maxPerTxnCandidate = Number(process.env.PAYMENT_MAX_PER_TXN || DEFAULT_PAYMENT_CONFIG.maxPerTxnAmount);
  const maxPerTxnAmount = Number.isFinite(maxPerTxnCandidate) && maxPerTxnCandidate > 0
    ? maxPerTxnCandidate
    : DEFAULT_PAYMENT_CONFIG.maxPerTxnAmount;

  const merchantId = (process.env.PAYMENT_MERCHANT_ID || DEFAULT_PAYMENT_CONFIG.merchantId).trim();
  const merchantDisplayName = (process.env.PAYMENT_MERCHANT_NAME || DEFAULT_PAYMENT_CONFIG.merchantDisplayName).trim();
  const recipientPhone = (process.env.PAYMENT_RECIPIENT_PHONE || DEFAULT_PAYMENT_CONFIG.recipientPhone).trim();
  const trustedQrRaw = (process.env.PAYMENT_TRUSTED_QR_RAW || DEFAULT_PAYMENT_CONFIG.trustedQrRaw).trim();

  return {
    merchantId: merchantId || DEFAULT_PAYMENT_CONFIG.merchantId,
    merchantDisplayName: merchantDisplayName || DEFAULT_PAYMENT_CONFIG.merchantDisplayName,
    recipientPhone: recipientPhone || DEFAULT_PAYMENT_CONFIG.recipientPhone,
    trustedQrFingerprint: fingerprintQR(trustedQrRaw),
    maxPerTxnAmount
  };
}

function buildFallbackPerceptionResponse(mode, prompt, ocrText) {
  const normalizedMode = typeof mode === 'string' ? mode : 'scene';
  const cleanOCR = typeof ocrText === 'string' ? ocrText.trim() : '';
  const cleanPrompt = typeof prompt === 'string' ? prompt.trim() : '';

  const fields = {};
  cleanOCR.split('\n').forEach((line) => {
    const idx = line.indexOf(':');
    if (idx > 0 && idx < line.length - 1) {
      const key = line.slice(0, idx).trim();
      const value = line.slice(idx + 1).trim();
      if (key && value) {
        fields[key] = value;
      }
    }
  });

  let summary = 'I can see the scene, but details are limited right now.';
  if (normalizedMode === 'read') {
    if (cleanOCR.length > 0) {
      summary = `Detected text: ${cleanOCR.slice(0, 220)}${cleanOCR.length > 220 ? '...' : ''}`;
    } else {
      summary = 'No readable text found yet. Move closer and improve lighting.';
    }
  } else if (normalizedMode === 'document') {
    if (Object.keys(fields).length > 0) {
      summary = `Parsed ${Object.keys(fields).length} document fields from visible text.`;
    } else if (cleanOCR.length > 0) {
      summary = `Document text captured: ${cleanOCR.slice(0, 220)}${cleanOCR.length > 220 ? '...' : ''}`;
    } else {
      summary = 'No document text detected. Try holding the camera steady.';
    }
  } else if (cleanPrompt) {
    summary = cleanPrompt.slice(0, 220);
  }

  return {
    provider: 'fallback',
    mode: normalizedMode,
    summary,
    structuredFields: fields
  };
}

function buildPerceptionInstruction(mode, prompt, ocrText) {
  const normalizedMode = typeof mode === 'string' ? mode : 'scene';
  const lines = [];
  if (prompt && typeof prompt === 'string') {
    lines.push(`Task: ${prompt.trim()}`);
  }

  if (normalizedMode === 'scene') {
    lines.push('Describe the scene for a blind user in 1-2 concise sentences.');
    lines.push('Prioritize navigation and safety-relevant details.');
  } else if (normalizedMode === 'read') {
    lines.push('Read and explain visible text briefly and clearly.');
  } else {
    lines.push('Extract key fields from visible document text.');
    lines.push('Return concise summary plus structured fields.');
  }

  const cleanOCR = typeof ocrText === 'string' ? ocrText.trim() : '';
  if (cleanOCR) {
    lines.push(`OCR context:\n${cleanOCR.slice(0, 2500)}`);
  }

  lines.push('Output JSON only with keys: summary (string), structuredFields (object).');
  return lines.join('\n\n');
}

function parseStructuredFieldsFromText(text) {
  if (typeof text !== 'string' || !text.trim()) return {};

  const fencedMatch = text.match(/```json\s*([\s\S]*?)```/i);
  const jsonCandidate = fencedMatch ? fencedMatch[1] : text;
  try {
    const parsed = JSON.parse(jsonCandidate);
    if (parsed && typeof parsed === 'object') {
      if (parsed.structuredFields && typeof parsed.structuredFields === 'object') {
        return parsed.structuredFields;
      }
      const rest = { ...parsed };
      delete rest.summary;
      return rest;
    }
  } catch (_) {
    // Fall through to colon-line extraction.
  }

  const fields = {};
  text.split('\n').forEach((line) => {
    const idx = line.indexOf(':');
    if (idx > 0 && idx < line.length - 1) {
      const key = line.slice(0, idx).trim().replace(/^[-*\d.\s]+/, '');
      const value = line.slice(idx + 1).trim();
      if (key && value && key.length <= 80) {
        fields[key] = value;
      }
    }
  });
  return fields;
}

function parseLMStudioChatResponse(data) {
  const choice = data?.choices?.[0];
  const content = choice?.message?.content;

  if (typeof content === 'string') {
    let summary = content.trim();
    try {
      const parsed = JSON.parse(summary);
      if (parsed && typeof parsed === 'object') {
        return {
          summary: typeof parsed.summary === 'string' ? parsed.summary.trim() : summary,
          structuredFields: parsed.structuredFields && typeof parsed.structuredFields === 'object'
            ? parsed.structuredFields
            : parseStructuredFieldsFromText(summary)
        };
      }
    } catch (_) {
      // Not strict JSON output.
    }
    return {
      summary,
      structuredFields: parseStructuredFieldsFromText(summary)
    };
  }

  if (Array.isArray(content)) {
    const textPart = content.find((part) => part && part.type === 'text' && typeof part.text === 'string');
    const summary = textPart ? textPart.text.trim() : '';
    return {
      summary,
      structuredFields: parseStructuredFieldsFromText(summary)
    };
  }

  return { summary: '', structuredFields: {} };
}

async function callMiniCPMViaLMStudio({ endpoint, timeoutMs, apiKey, mode, prompt, ocrText, imageBase64 }) {
  const model = (process.env.MINICPM_MODEL || '').trim();
  if (!model) {
    throw new Error('MINICPM_MODEL is required for LM Studio mode.');
  }

  const instruction = buildPerceptionInstruction(mode, prompt, ocrText);
  const userContent = [{ type: 'text', text: instruction }];
  if (typeof imageBase64 === 'string' && imageBase64.trim().length > 0) {
    userContent.push({
      type: 'image_url',
      image_url: { url: `data:image/jpeg;base64,${imageBase64}` }
    });
  }

  const payload = {
    model,
    temperature: Number(process.env.MINICPM_TEMPERATURE || 0.2),
    max_tokens: Number(process.env.MINICPM_MAX_TOKENS || 350),
    messages: [
      {
        role: 'system',
        content: 'You are an accessibility assistant for scene understanding and document reading.'
      },
      {
        role: 'user',
        content: userContent
      }
    ]
  };

  const headers = { 'Content-Type': 'application/json' };
  if (apiKey) {
    headers.Authorization = `Bearer ${apiKey}`;
  }

  const response = await axios.post(endpoint, payload, { headers, timeout: timeoutMs });
  return parseLMStudioChatResponse(response.data || {});
}

// Initialize wallet if it doesn't exist
async function getOrCreateWallet() {
  let wallet = await Wallet.findOne();
  if (!wallet) {
    wallet = new Wallet({ balance: 0 });
    await wallet.save();
  }
  return wallet;
}

// Get wallet balance
router.get('/balance', async (req, res) => {
  try {
    const wallet = await getOrCreateWallet();
    res.json({ balance: wallet.balance });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Get strict payment configuration for app clients
router.get('/payment-config', (req, res) => {
  const cfg = getPaymentConfig();
  res.json({
    merchantId: cfg.merchantId,
    merchantDisplayName: cfg.merchantDisplayName,
    trustedQrFingerprint: cfg.trustedQrFingerprint,
    maxPerTxnAmount: cfg.maxPerTxnAmount
  });
});

// Add funds (deposit)
router.post('/add-funds', async (req, res) => {
  try {
    const { amount: rawAmount, description } = req.body || {};
    const amount = parsePositiveAmount(rawAmount);

    if (!amount) {
      return res.status(400).json({ error: 'Invalid amount' });
    }

    const wallet = await getOrCreateWallet();
    wallet.balance += amount;
    await wallet.save();

    const transaction = new Transaction({
      type: 'deposit',
      amount,
      description: description || 'Add funds'
    });
    await transaction.save();

    const message = `💰 <b>Funds Added</b>\n` +
      `Amount: ₹${amount.toFixed(2)}\n` +
      `Description: ${description || 'N/A'}\n` +
      `New Balance: ₹${wallet.balance.toFixed(2)}`;
    await sendTelegramMessage(message);

    res.json({
      balance: wallet.balance,
      transaction
    });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Send money (withdrawal) - strict single-merchant flow with idempotency.
router.post('/send-money', async (req, res) => {
  const body = req.body || {};
  const config = getPaymentConfig();
  let idempotencyKey = '';
  let transaction = null;

  try {
    const amount = parsePositiveAmount(body.amount);
    if (!amount) {
      return res.status(400).json({ error: 'Invalid amount' });
    }

    if (amount > config.maxPerTxnAmount) {
      return res.status(400).json({ error: `Amount exceeds max per transaction (₹${config.maxPerTxnAmount}).` });
    }

    const requestMerchantId = typeof body.merchantId === 'string' && body.merchantId.trim().length > 0
      ? body.merchantId.trim()
      : config.merchantId;
    if (requestMerchantId !== config.merchantId) {
      return res.status(400).json({ error: 'Unknown or unauthorized merchant.' });
    }

    if (typeof body.recipientPhone === 'string' && body.recipientPhone.trim().length > 0) {
      if (body.recipientPhone.trim() !== config.recipientPhone) {
        return res.status(400).json({ error: 'Recipient does not match trusted merchant configuration.' });
      }
    }

    idempotencyKey = typeof body.idempotencyKey === 'string' ? body.idempotencyKey.trim() : '';
    if (!idempotencyKey) {
      return res.status(400).json({ error: 'idempotencyKey is required.' });
    }

    const existing = await Transaction.findOne({ idempotencyKey });
    if (existing) {
      const wallet = await getOrCreateWallet();
      return res.json({
        balance: wallet.balance,
        transactionId: existing._id,
        status: existing.status,
        merchantDisplayName: existing.merchantDisplayName || config.merchantDisplayName,
        transaction: existing,
        idempotentReplay: true
      });
    }

    transaction = await Transaction.create({
      type: 'withdrawal',
      amount,
      recipientPhone: config.recipientPhone,
      merchantId: config.merchantId,
      merchantDisplayName: config.merchantDisplayName,
      idempotencyKey,
      authMethod: typeof body.authMethod === 'string' ? body.authMethod.trim() : 'face_id',
      description: body.description || `QR payment to ${config.merchantDisplayName}`,
      status: 'pending'
    });

    const wallet = await getOrCreateWallet();
    if (wallet.balance < amount) {
      transaction.status = 'failed';
      transaction.failureReason = 'Insufficient balance';
      await transaction.save();
      return res.status(400).json({
        error: 'Insufficient balance',
        transactionId: transaction._id,
        status: transaction.status
      });
    }

    wallet.balance -= amount;
    await wallet.save();
    transaction.status = 'completed';
    transaction.failureReason = '';
    await transaction.save();

    const message = `💸 <b>Money Sent</b>\n` +
      `Amount: ₹${amount.toFixed(2)}\n` +
      `Merchant: ${transaction.merchantDisplayName}\n` +
      `To: ${transaction.recipientPhone}\n` +
      `Auth: ${transaction.authMethod || 'N/A'}\n` +
      `Transaction ID: ${transaction._id}\n` +
      `New Balance: ₹${wallet.balance.toFixed(2)}`;
    await sendTelegramMessage(message);

    res.json({
      balance: wallet.balance,
      transactionId: transaction._id,
      status: transaction.status,
      merchantDisplayName: transaction.merchantDisplayName,
      transaction
    });
  } catch (error) {
    if (error && error.code === 11000 && idempotencyKey) {
      const existing = await Transaction.findOne({ idempotencyKey });
      const wallet = await getOrCreateWallet();
      if (existing) {
        return res.json({
          balance: wallet.balance,
          transactionId: existing._id,
          status: existing.status,
          merchantDisplayName: existing.merchantDisplayName || config.merchantDisplayName,
          transaction: existing,
          idempotentReplay: true
        });
      }
    }

    if (transaction && transaction.status === 'pending') {
      try {
        transaction.status = 'failed';
        transaction.failureReason = error.message || 'Unexpected payment error';
        await transaction.save();
      } catch (_) {
        // Ignore follow-up persistence failure while returning the primary error.
      }
    }
    res.status(500).json({ error: error.message });
  }
});

// MiniCPM proxy endpoint retained as a compatibility/debug fallback when on-device inference is unavailable.
router.post('/perception/analyze', async (req, res) => {
  try {
    const { mode = 'scene', prompt = '', ocrText = '', imageBase64 = '' } = req.body || {};
    const endpoint = process.env.MINICPM_API_URL;
    const provider = (process.env.MINICPM_PROVIDER || '').trim().toLowerCase();
    const timeoutMs = Number(process.env.MINICPM_TIMEOUT_MS || 15000);
    const apiKey = process.env.MINICPM_API_KEY;

    if (!endpoint) {
      return res.json(buildFallbackPerceptionResponse(mode, prompt, ocrText));
    }

    let summary = '';
    let structuredFields = {};
    let responseProvider = 'minicpm-proxy';

    const looksLikeChatCompletions = endpoint.includes('/chat/completions');
    if (provider === 'lmstudio' || provider === 'openai-chat' || looksLikeChatCompletions) {
      const parsed = await callMiniCPMViaLMStudio({
        endpoint,
        timeoutMs,
        apiKey,
        mode,
        prompt,
        ocrText,
        imageBase64
      });
      summary = parsed.summary;
      structuredFields = parsed.structuredFields;
      responseProvider = 'lmstudio';
    } else {
      const headers = { 'Content-Type': 'application/json' };
      if (apiKey) {
        headers.Authorization = `Bearer ${apiKey}`;
      }
      const payload = {
        mode,
        prompt,
        ocrText,
        imageBase64
      };
      const response = await axios.post(endpoint, payload, { headers, timeout: timeoutMs });
      const data = response.data || {};
      if (typeof data === 'string') {
        summary = data;
      } else {
        summary = typeof data.summary === 'string' ? data.summary : '';
        structuredFields = data.structuredFields && typeof data.structuredFields === 'object'
          ? data.structuredFields
          : {};
      }
    }

    const fallback = buildFallbackPerceptionResponse(mode, prompt, ocrText);
    res.json({
      provider: responseProvider,
      mode,
      summary: summary && summary.trim().length > 0 ? summary : fallback.summary,
      structuredFields: structuredFields && Object.keys(structuredFields).length > 0
        ? structuredFields
        : fallback.structuredFields
    });
  } catch (error) {
    const fallback = buildFallbackPerceptionResponse(req.body?.mode, req.body?.prompt, req.body?.ocrText);
    res.json({
      ...fallback,
      warning: `MiniCPM endpoint unavailable: ${error.message}`
    });
  }
});

// Get all transactions
router.get('/transactions', async (req, res) => {
  try {
    const transactions = await Transaction.find().sort({ createdAt: -1 });
    res.json(transactions);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Telegram test notification
router.get('/telegram-test', async (req, res) => {
  try {
    if (!process.env.TELEGRAM_BOT_TOKEN || !process.env.TELEGRAM_CHAT_ID) {
      return res.status(400).json({
        error: 'Telegram not configured. Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in .env'
      });
    }

    const message = `✅ <b>Telegram Test</b>\nThis is a test message from the Digital Wallet backend.`;
    const ok = await sendTelegramMessage(message);
    if (!ok) {
      return res.status(500).json({ error: 'Telegram send failed. Check bot token, chat ID, and bot permissions.' });
    }
    res.json({ ok: true });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

module.exports = router;
