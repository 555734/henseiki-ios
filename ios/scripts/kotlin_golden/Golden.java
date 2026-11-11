import com.voiceclone.app.AudioDsp;
import com.voiceclone.app.IrodoriEngine;
import com.voiceclone.app.UnigramTokenizer;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;

/** Runs the real Android (Kotlin) code on the parity inputs and writes the results as JSON. */
public class Golden {
    static String q(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"') b.append("\\\""); else if (c == '\\') b.append("\\\\"); else if (c == '\n') b.append("\\n");
            else if (c == '\t') b.append("\\t"); else if (c == '\r') b.append("\\r"); else if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
            else b.append(c);
        }
        return b.append('"').toString();
    }
    static String arr(float[] v) { StringBuilder b = new StringBuilder("["); for (int i = 0; i < v.length; i++) { if (i > 0) b.append(','); b.append(Float.toString(v[i])); } return b.append(']').toString(); }
    static String arr(int[] v) { StringBuilder b = new StringBuilder("["); for (int i = 0; i < v.length; i++) { if (i > 0) b.append(','); b.append(v[i]); } return b.append(']').toString(); }
    static float[] head(float[] v, int n) { return Arrays.copyOf(v, Math.min(n, v.length)); }
    static float[] tail(float[] v, int n) { return Arrays.copyOfRange(v, Math.max(0, v.length - n), v.length); }

    // Minimal JSON string-array reader (the inputs are plain arrays of strings).
    static List<String> strings(String json) {
        List<String> out = new ArrayList<>();
        int i = json.indexOf('[') + 1;
        while (i < json.length()) {
            char c = json.charAt(i);
            if (c == '"') {
                StringBuilder s = new StringBuilder(); i++;
                while (json.charAt(i) != '"') {
                    char d = json.charAt(i);
                    if (d == '\\') { i++; char e = json.charAt(i);
                        if (e == 'n') s.append('\n'); else if (e == 't') s.append('\t'); else if (e == 'u') { s.append((char) Integer.parseInt(json.substring(i + 1, i + 5), 16)); i += 4; } else s.append(e);
                    } else s.append(d);
                    i++;
                }
                out.add(s.toString());
            } else if (c == ']') break;
            i++;
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        File fixtures = new File(args[0]);
        // tokenizer
        UnigramTokenizer tok = UnigramTokenizer.Companion.load(new File(fixtures, "tokenizer_synthetic.json"), true);
        UnigramTokenizer plain = UnigramTokenizer.Companion.load(new File(fixtures, "tokenizer_synthetic.json"), false);
        StringBuilder t = new StringBuilder("{\"bos\":" + tok.getBosId() + ",\"cases\":[");
        List<String> texts = strings(new String(Files.readAllBytes(new File(fixtures, "tokenizer_texts.json").toPath()), StandardCharsets.UTF_8));
        for (int i = 0; i < texts.size(); i++) {
            if (i > 0) t.append(',');
            t.append("{\"text\":" + q(texts.get(i)) + ",\"ids\":" + arr(tok.encode(texts.get(i))) + ",\"idsNoRareSplit\":" + arr(plain.encode(texts.get(i))) + "}");
        }
        Files.write(new File(fixtures, "tokenizer_golden.json").toPath(), t.append("]}").toString().getBytes(StandardCharsets.UTF_8));

        // text preparation
        List<String> prep = strings(new String(Files.readAllBytes(new File(fixtures, "text_prep_texts.json").toPath()), StandardCharsets.UTF_8));
        StringBuilder p = new StringBuilder("[");
        for (int i = 0; i < prep.size(); i++) {
            if (i > 0) p.append(',');
            StringBuilder parts = new StringBuilder("[");
            List<String> sentences = IrodoriEngine.Companion.splitSentences(prep.get(i));
            for (int j = 0; j < sentences.size(); j++) { if (j > 0) parts.append(','); parts.append(q(sentences.get(j))); }
            p.append("{\"text\":" + q(prep.get(i)) + ",\"normalized\":" + q(IrodoriEngine.Companion.normalizeText(prep.get(i))) + ",\"sentences\":" + parts.append(']') + "}");
        }
        Files.write(new File(fixtures, "text_prep_golden.json").toPath(), p.append("]").toString().getBytes(StandardCharsets.UTF_8));

        // DSP on deterministic signals
        int n = 48000 * 3;
        float[] speech = new float[n];
        for (int i = 0; i < n; i++) {
            double env = 0.5 + 0.5 * Math.sin(2 * Math.PI * 2.0 * i / 48000);
            speech[i] = (float) (0.3 * env * Math.sin(2 * Math.PI * 220.0 * i / 48000) + 0.1 * Math.sin(2 * Math.PI * 1000.0 * i / 48000));
        }
        float[] padded = new float[48000];
        for (int i = 0; i < padded.length; i++) padded[i] = (float) (0.4 * Math.sin(2 * Math.PI * 440.0 * i / 48000));
        float[] gapped = new float[48000 * 2];
        for (int i = 24000; i < 24000 + 20000; i++) gapped[i] = (float) (0.2 * Math.sin(2 * Math.PI * 300.0 * i / 48000));
        float[] odd = new float[5003];
        for (int i = 0; i < odd.length; i++) odd[i] = (float) Math.sin(i * 0.01);
        float[] normalized = AudioDsp.INSTANCE.normalizeLoudness(speech, -16.0);
        float[] loud = new float[n]; for (int i = 0; i < n; i++) loud[i] = speech[i] * 9f;
        float[] normalizedLoud = AudioDsp.INSTANCE.normalizeLoudness(loud, -10.0);
        float[] reflect = AudioDsp.INSTANCE.reflectPad(odd, 1920);
        float[] trimmed = AudioDsp.INSTANCE.trimSilence(gapped, 48000);
        float[] resampled = AudioDsp.INSTANCE.resample(padded, 44100, 48000);
        StringBuilder d = new StringBuilder("{");
        d.append("\"loudness\":" + AudioDsp.INSTANCE.integratedLoudness(speech));
        d.append(",\"normalizedLength\":" + normalized.length + ",\"normalizedHead\":" + arr(head(normalized, 6)) + ",\"normalizedTail\":" + arr(tail(normalized, 6)) + ",\"normalizedSum\":" + sum(normalized));
        d.append(",\"loudLength\":" + normalizedLoud.length + ",\"loudHead\":" + arr(head(normalizedLoud, 6)) + ",\"loudSum\":" + sum(normalizedLoud));
        d.append(",\"reflectLength\":" + reflect.length + ",\"reflectTail\":" + arr(tail(reflect, 8)));
        d.append(",\"trimLength\":" + trimmed.length + ",\"trimHead\":" + arr(head(trimmed, 4)) + ",\"trimSum\":" + sum(trimmed));
        d.append(",\"resampleLength\":" + resampled.length + ",\"resampleHead\":" + arr(head(resampled, 6)) + ",\"resampleTail\":" + arr(tail(resampled, 4)) + ",\"resampleSum\":" + sum(resampled));
        // java.util.Random
        Random r = new Random(42);
        StringBuilder g = new StringBuilder("[");
        for (int i = 0; i < 12; i++) { if (i > 0) g.append(','); g.append(Double.toString(r.nextGaussian())); }
        Random r2 = new Random(0); StringBuilder g2 = new StringBuilder("[");
        for (int i = 0; i < 6; i++) { if (i > 0) g2.append(','); g2.append(Double.toString(r2.nextGaussian())); }
        d.append(",\"gaussian42\":" + g.append(']') + ",\"gaussian0\":" + g2.append(']'));
        Files.write(new File(fixtures, "dsp_golden.json").toPath(), d.append("}").toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("golden files written");
    }

    static double sum(float[] v) { double s = 0; for (float x : v) s += x; return s; }
}
